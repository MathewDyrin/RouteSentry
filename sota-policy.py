import argparse
import concurrent.futures
import fcntl
import hashlib
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import ipaddress
import json
import re
from pathlib import Path

KEYS = ('vpn_only', 'not_vpn_only')
LABEL = re.compile(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z')
UUID = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
TUNNEL = r'(?:utun|ipsec|ppp|tun|tap)[0-9]+'


def parse_policy(data):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'Duplicate field: {key}')
            result[key] = value
        return result

    policy = json.loads(data, object_pairs_hook=unique_object)
    if not isinstance(policy, dict) or not set(KEYS) <= policy.keys() or policy.keys() - {*KEYS, 'vpn_profile'}:
        raise ValueError('The config requires vpn_only and not_vpn_only. vpn_profile is optional.')
    profile = policy.get('vpn_profile', 'auto')
    if not isinstance(profile, str) or (profile not in {'auto', 'route'} and not re.fullmatch(UUID, profile, re.I)):
        raise ValueError('vpn_profile must be auto, route, or a macOS VPN profile ID.')

    result = {}
    for key in KEYS:
        entries = policy[key]
        if not isinstance(entries, list):
            raise ValueError(f'{key} must be a list.')
        domains = set()
        networks = set()
        for index, value in enumerate(entries, start=1):
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f'{key}[{index}]: enter a nonempty string.')
            value = value.strip()
            try:
                networks.add(ipaddress.ip_network(value))
                continue
            except ValueError:
                pass
            try:
                domain = value.rstrip('.').lower().encode('idna').decode('ascii')
            except UnicodeError as error:
                raise ValueError(f'{key}[{index}]: invalid domain.') from error
            labels = domain.split('.')
            if (
                len(domain) > 253 or len(labels) < 2 or labels[-1].isdigit()
                or not all(LABEL.fullmatch(label) for label in labels)
            ):
                raise ValueError(f'{key}[{index}]: enter a domain, IP address, or CIDR.')
            domains.add(domain)
        result[key] = domains, networks

    vpn_domains, vpn_networks = result['vpn_only']
    direct_domains, direct_networks = result['not_vpn_only']
    shared_domains = vpn_domains & direct_domains
    if shared_domains:
        raise ValueError(f'Domains in both lists: {", ".join(sorted(shared_domains))}')
    for vpn in vpn_networks:
        for direct in direct_networks:
            if vpn.version == direct.version and vpn.overlaps(direct):
                raise ValueError(f'Networks {vpn} and {direct} overlap across lists.')
    return result, normalize_selection(profile)


def read_policy(path):
    return parse_policy(Path(path).read_bytes())


LABEL_NAME = 'local.sota-selective-policy'
ANCHOR = 'com.apple/zz.local.sota-selective-policy'
DATA = Path('/Library/Application Support/SotaSelectivePolicy')
SERVICE = Path('/Library/LaunchDaemons') / f'{LABEL_NAME}.plist'
INSTALLED = DATA / 'sota-policy.py'
CONFIG = DATA / 'policy.json'
RESOLVED = DATA / 'resolved.json'
SEED = DATA / 'seed.json'
REFERENCE = DATA / 'pf-reference.json'
APPLIED = DATA / 'applied.json'
JOB = f'system/{LABEL_NAME}'
PF = '/sbin/pfctl'
LAUNCHCTL = '/bin/launchctl'
ACTIVE = {'Connected', 'Connecting', 'Reasserting', 'Disconnecting'}


def command(args, *, data=None, check=True):
    proc = subprocess.run(args, input=data, text=True, capture_output=True, timeout=8)
    if check and proc.returncode:
        raise RuntimeError(f'{args[0]}: {(proc.stderr or proc.stdout).strip()}')
    return proc


def parse_profiles(output):
    pattern = re.compile(
        rf'^\s*(?P<enabled>\*?)\s*\((?P<status>[^)]+)\)\s+(?P<id>{UUID})\s+'
        r'(?P<type>.*?)\s+"(?P<name>.*)"\s+\[(?P<kind>[^\]]+)\]\s*$', re.I | re.M
    )
    profiles = []
    for match in pattern.finditer(output):
        profile = match.groupdict()
        if not re.match(r'^(?:VPN|IPSec|IKEv2|PPP:(?:L2TP|PPTP))(?:$|:)', profile['kind'], re.I):
            continue
        profiles.append({'id': profile['id'].upper(), 'name': profile['name'],
                         'status': profile['status'], 'enabled': bool(profile['enabled'])})
    return profiles


def normalize_selection(selection):
    return selection if selection in {'auto', 'route'} else selection.upper()


def choose_profile(profiles, selection):
    if selection == 'route':
        return None, None
    if selection != 'auto':
        profile = next((profile for profile in profiles if profile['id'] == selection), None)
        return profile, None if profile else 'missing'
    active = [profile for profile in profiles if profile['status'] in ACTIVE]
    if len(active) == 1:
        return active[0], None
    if len(active) > 1:
        return None, 'ambiguous'
    if not profiles:
        return None, 'missing'
    available = [profile for profile in profiles if profile['enabled']] or profiles
    return (available[0], None) if len(available) == 1 else (None, 'idle')


def routed_tunnel():
    interfaces = []
    # Kernel route lookups only; no packets are sent to these destinations.
    for destination in ('93.184.216.34', '151.101.1.69'):
        output = command(['/sbin/route', '-n', 'get', '-inet', destination], check=False).stdout
        match = re.search(r'^\s*interface:\s*(\w+)\s*$', output, re.M)
        interfaces.append(match[1] if match else '')
    if len(set(interfaces)) == 1 and re.fullmatch(TUNNEL, interfaces[0]):
        return 'Connected', interfaces[0]
    if all(interfaces) and not any(re.fullmatch(TUNNEL, value) for value in interfaces):
        return 'Disconnected', None
    return 'Unknown', None


def vpn_snapshot(selection):
    scutil = '/usr/sbin/scutil'
    result = command([scutil, '--nc', 'list'], check=False)
    profiles = parse_profiles(result.stdout) if result.returncode == 0 else []
    profile, issue = choose_profile(profiles, selection)
    snapshot = {'profiles': profiles, 'profile_name': profile['name'] if profile else None,
                'vpn_status': 'Disconnected' if issue == 'idle' else 'Unknown',
                'tunnel': None, 'vpn_issue': issue}
    if selection == 'route' or (selection == 'auto' and issue != 'ambiguous'
                                and (not profile or profile['status'] not in ACTIVE)):
        route_status, interface = routed_tunnel()
        if selection == 'route' or interface:
            if not interface and any(profile['status'] in ACTIVE for profile in profiles):
                route_status = 'Unknown'
            snapshot.update(profile_name='Routed tunnel', vpn_status=route_status, tunnel=interface,
                            vpn_issue='route_unclear' if route_status == 'Unknown' else None)
            return snapshot
    if profile is None:
        return snapshot
    result = command([scutil, '--nc', 'status', profile['id']], check=False)
    lines = result.stdout.splitlines()
    status = lines[0].strip() if lines and result.returncode == 0 else 'Unknown'
    if status not in ACTIVE | {'Disconnected', 'Invalid'}:
        status = 'Unknown'
    snapshot['vpn_status'] = status
    if status == 'Connected':
        interfaces = set(re.findall(rf'^\s*InterfaceName\s*:\s*({TUNNEL})\s*$', result.stdout, re.M))
        if not interfaces:
            keys = ''.join(f'show State:/Network/Service/{profile["id"]}/{family}\n' for family in ('IPv4', 'IPv6'))
            details = command([scutil], data=keys + 'quit\n', check=False).stdout
            interfaces = set(re.findall(rf'^\s*InterfaceName\s*:\s*({TUNNEL})\s*$', details, re.M))
        if len(interfaces) == 1:
            snapshot['tunnel'] = interfaces.pop()
        else:
            snapshot['vpn_issue'] = 'no_interface'
    return snapshot


def resolve(domains):
    answers = {}
    for domain in domains:
        try:
            records = socket.getaddrinfo(domain + '.', None, type=socket.SOCK_STREAM)
        except OSError:
            continue
        answers[domain] = {str(ipaddress.ip_address(row[4][0].split('%')[0])) for row in records}
    return answers


def targets(policy, cache):
    effective = {}
    for key, (domains, networks) in policy.items():
        addresses = networks | {
            ipaddress.ip_network(addr)
            for domain in domains
            for addr in cache.get(domain, {})
        }
        effective[key] = tuple(
            str(net) for version in (4, 6)
            for net in ipaddress.collapse_addresses(net for net in addresses if net.version == version)
        )
    return effective


def rules_for(effective, status, tunnel):
    rules = []
    for key in KEYS:
        if effective[key]:
            rules.append(f'table <{key}> const {{ {", ".join(effective[key])} }}')
    if effective['not_vpn_only'] and status in ACTIVE | {'Unknown'}:
        rules.append('block drop out quick from any to <not_vpn_only>')
    if effective['vpn_only']:
        scope = f' on ! {tunnel}' if tunnel else ''
        rules.append(f'block drop out quick{scope} from any to <vpn_only>')
    return '\n'.join(rules) + '\n'


def pf_load(rules, dry_run=False):
    args = [PF, '-a', ANCHOR, '-f', '-']
    if dry_run:
        args.insert(1, '-n')
    return command(args, data=rules)


def current_boot():
    return command(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']).stdout.strip()


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return default


def atomic_write(path, data, mode=0o644):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(data)
            file.flush()
            os.fchmod(file.fileno(), mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def save_json(path, data):
    atomic_write(path, (json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode())


def require_root():
    if os.geteuid():
        raise RuntimeError('This command requires administrator privileges.')


def ensure_pf():
    main = command([PF, '-sr']).stdout
    if not re.search(r'^\s*anchor\s+"com\.apple/\*"(?:\s|$)', main, re.M):
        raise RuntimeError('The active PF ruleset is missing the com.apple/* anchor. No rules were loaded.')
    previous = read_json(REFERENCE, {})
    boot = current_boot()
    if previous.get('boot') == boot:
        refs = command([PF, '-s', 'References']).stdout
        if re.search(rf'\b{re.escape(previous["token"])}\b', refs):
            return
    result = command([PF, '-E'])
    token = re.search(r'\bToken\s*:\s*(\d+)', result.stdout + result.stderr)
    if not token:
        raise RuntimeError('PF did not return an enable token.')
    save_json(REFERENCE, {'boot': boot, 'token': token[1]})


def forget_states(networks):
    for net in networks:
        source = '::/0' if ':' in net else '0.0.0.0/0'
        command([PF, '-k', source, '-k', net])


def serve():
    require_root()
    lock = (DATA / 'service.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    policy, profile = read_policy(CONFIG)
    cache = read_json(RESOLVED, {})
    config_version = None
    applied_rules = None
    applied_state = None
    last_error = None
    next_dns = 0
    lookup = None
    worker = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    boot = current_boot()
    while True:
        try:
            config_stat = CONFIG.stat()
            version = (config_stat.st_ino, config_stat.st_mtime_ns)
            if version != config_version:
                config_data = CONFIG.read_bytes()
                policy, profile = parse_policy(config_data)
                config_digest = hashlib.sha256(config_data).hexdigest()
                for domain, addresses in read_json(SEED, {}).items():
                    cache.setdefault(domain, {}).update(addresses)
                config_version = version
                next_dns = 0
            domains = set.union(*(policy[key][0] for key in KEYS))
            now = time.time()
            if lookup and lookup.done():
                for domain, addresses in lookup.result().items():
                    if domain in domains and addresses:
                        saved = cache.setdefault(domain, {})
                        saved.update(dict.fromkeys(addresses, now))
                        cache[domain] = {addr: seen for addr, seen in saved.items() if now - seen < 86400}
                cache = {domain: cache[domain] for domain in domains if domain in cache}
                if read_json(RESOLVED, {}) != cache:
                    save_json(RESOLVED, cache)
                lookup = None
            if lookup is None and now >= next_dns:
                if domains:
                    lookup = worker.submit(resolve, sorted(domains))
                next_dns = now + 15
            vpn = vpn_snapshot(profile)
            status, tunnel = vpn['vpn_status'], vpn['tunnel']
            effective = targets(policy, cache)
            rules = rules_for(effective, status, tunnel)
            if rules != applied_rules:
                pf_load(rules, dry_run=True)
                ensure_pf()
                pf_load(rules)
                blocked = set(effective['vpn_only'])
                if status in ACTIVE | {'Unknown'}:
                    blocked.update(effective['not_vpn_only'])
                forget_states(sorted(blocked))
                applied_rules = rules
            state = {
                'boot': boot,
                'config_sha256': config_digest,
                'vpn_status': status,
                'profile_name': vpn['profile_name'],
                'vpn_issue': vpn['vpn_issue'],
                'tunnel': tunnel,
                'unresolved': sorted(domain for domain in domains if not cache.get(domain)),
                'vpn_only_networks': len(effective['vpn_only']),
                'not_vpn_only_networks': len(effective['not_vpn_only']),
            }
            if state != applied_state:
                save_json(APPLIED, state)
                applied_state = state
            last_error = None
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            if str(error) != last_error:
                print(error, file=sys.stderr, flush=True)
                last_error = str(error)
        time.sleep(0.5)


def install(source):
    require_root()
    config_data = Path(source).read_bytes()
    policy, _ = parse_policy(config_data)
    if not any(domains or nets for domains, nets in policy.values()):
        raise ValueError('Add at least one address or domain before applying rules.')
    domains = set.union(*(policy[key][0] for key in KEYS))
    answers = resolve(sorted(domains))
    unresolved = domains - answers.keys()
    if unresolved:
        raise ValueError('Config not applied. No DNS answer for: ' + ', '.join(sorted(unresolved)))
    seed = {domain: dict.fromkeys(addresses, time.time()) for domain, addresses in answers.items()}
    effective = targets(policy, seed)
    pf_load(rules_for(effective, 'Connected', 'utun5'), dry_run=True)
    pf_load(rules_for(effective, 'Disconnected', None), dry_run=True)
    DATA.mkdir(mode=0o755, exist_ok=True)
    if DATA.is_symlink() or DATA.stat().st_uid != 0 or DATA.stat().st_mode & 0o022:
        raise RuntimeError(f'Unsafe permissions on {DATA}.')
    save_json(SEED, seed)
    atomic_write(CONFIG, config_data)
    config_digest = hashlib.sha256(config_data).hexdigest()
    backend = Path(__file__).read_bytes()
    backend_changed = not INSTALLED.exists() or INSTALLED.read_bytes() != backend
    if backend_changed:
        atomic_write(INSTALLED, backend)
    service = {
        'Label': LABEL_NAME,
        'ProgramArguments': ['/usr/bin/python3', '-I', str(INSTALLED), 'serve'],
        'RunAtLoad': True,
        'KeepAlive': True,
        'StandardErrorPath': str(DATA / 'errors.log'),
    }
    if command([LAUNCHCTL, 'print', JOB], check=False).returncode:
        atomic_write(SERVICE, plistlib.dumps(service))
        command([LAUNCHCTL, 'bootstrap', 'system', str(SERVICE)])
    elif backend_changed:
        command([LAUNCHCTL, 'kickstart', '-k', JOB])
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        state = report_status()
        if state['running'] and state.get('config_sha256') == config_digest:
            print('Rules applied.')
            return
        time.sleep(0.25)
    error_log = DATA / 'errors.log'
    details = error_log.read_text(errors='replace').strip().splitlines()[-1:] if error_log.exists() else []
    raise RuntimeError('The service has not confirmed the new rules. ' + ' '.join(details))


def uninstall():
    require_root()
    if command([LAUNCHCTL, 'print', JOB], check=False).returncode == 0:
        command([LAUNCHCTL, 'bootout', JOB])
    if DATA.exists():
        command([PF, '-a', ANCHOR, '-F', 'rules'])
        reference = read_json(REFERENCE, {})
        if reference.get('boot') == current_boot():
            command([PF, '-X', reference['token']])
        shutil.rmtree(DATA)
    SERVICE.unlink(missing_ok=True)
    print('RouteSentry rules removed.')


def report_status():
    job = command([LAUNCHCTL, 'print', JOB], check=False)
    running = job.returncode == 0 and bool(re.search(r'^\s*state = running\s*$', job.stdout, re.M))
    state = read_json(APPLIED, {})
    if state.get('boot') != current_boot():
        state = {}
    return {
        **state,
        'installed': SERVICE.exists() or DATA.exists(),
        'running': running,
        'confirmed': running and bool(state.get('config_sha256')),
    }


def main():
    parser = argparse.ArgumentParser(description='RouteSentry address rules for macOS')
    parser.add_argument('action', choices=['validate', 'preview', 'install', 'status', 'uninstall', 'serve'])
    parser.add_argument('config', type=Path, nargs='?', default=Path(__file__).with_suffix('.json'))
    parser.add_argument('--profile', default='auto')
    args = parser.parse_args()
    try:
        if args.action == 'validate':
            read_policy(args.config)
        elif args.action == 'preview':
            policy, profile = read_policy(args.config)
            domains = set.union(*(policy[key][0] for key in KEYS))
            cache = resolve(sorted(domains))
            effective = targets(policy, cache)
            tunnel = vpn_snapshot(profile)['tunnel']
            for label, state, device in [
                ('VPN connected', 'Connected', tunnel or 'utun0'),
                ('VPN disconnected', 'Disconnected', None),
            ]:
                rules = rules_for(effective, state, device)
                pf_load(rules, dry_run=True)
                print(f'{label}\n{rules}')
            if domains - cache.keys():
                print('No DNS answer for: ' + ', '.join(sorted(domains - cache.keys())), file=sys.stderr)
                return 1
        elif args.action == 'install':
            install(args.config)
        elif args.action == 'status':
            profile = args.profile
            if profile not in {'auto', 'route'} and not re.fullmatch(UUID, profile, re.I):
                raise ValueError('Invalid VPN profile ID.')
            status = report_status()
            status['discovery'] = vpn_snapshot(normalize_selection(profile))
            print(json.dumps(status, ensure_ascii=False, indent=2))
        elif args.action == 'uninstall':
            uninstall()
        else:
            serve()
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'{error}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
