"""Strict provenance for app-only recapture and synthesis-collection recovery.

This module cannot launch a process, implementation, or collection operation.
The public launcher and production TUI remain the only mutation routes.
"""
import hashlib
import json
from pathlib import Path


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def field(record, key):
    return dict(record)[key]


def bound_json(entry, label):
    path = Path(entry['path'])
    require(path.is_absolute() and path.resolve() == path, label + ': canonical exact path')
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == entry['sha256'], label + ': exact original bytes')
    return path, json.loads(raw)


def verify_files(files, store=None):
    require(bool(files), 'nonempty preservation inventory')
    for name, digest in files.items():
        path = Path(name)
        require(path.is_absolute() and (store is None or path.resolve().is_relative_to(store)),
                'preserved file belongs to exact store: ' + name)
        require(sha(path) == digest, 'preserved original bytes: ' + name)


def immutable_files(manifest):
    generation = Path(manifest['generation'])
    files = {str(generation / name): digest for name, digest in manifest['captured_files'].items()}
    files[str(generation / 'manifest.json')] = sha(generation / 'manifest.json')
    return files


def history_files(store):
    # Locks may be opened by the launcher but their bytes must not change.
    return {str(p): sha(p) for name in ('state', 'client-state', 'asic-results', 'preparation-results')
            for p in (store / name).rglob('*') if p.is_file()}


def load_inputs(path, store, check_app_sources=True):
    require(path is not None, '--recovery-inputs required')
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path and path.is_relative_to(Path('/tmp/opencode')),
            'private canonical recovery-inputs receipt')
    descriptor_raw = path.read_bytes()
    descriptor = json.loads(descriptor_raw)
    require(descriptor.get('schema_version') == 1 and
            descriptor.get('kind') == 'workbench-synthesis-collection-recovery-v1' and
            descriptor['store'] == str(store), 'explicit same-store recovery descriptor')
    failed_path, failed = bound_json(descriptor['failed_receipt'], 'failed acceptance receipt')
    _, diagnosis = bound_json(descriptor['diagnosis'], 'independent diagnosis')
    summary_path, summary = bound_json(descriptor['resource_summary'], 'original resource summary')
    outputs_path, outputs = bound_json(descriptor['tool_outputs'], 'original tool-output manifest')
    require(failed['status'] == 'failed' and failed['phase'] == 'synthesis' and failed['eda_jobs'] == 1 and
            failed['store'] == str(store), 'only a failed post-synthesis acceptance is recoverable')
    old_path = Path(failed['generation']) / 'manifest.json'
    require(old_path.parent.parent == store / 'generations' and old_path.resolve() == old_path and
            sha(old_path) == failed['manifest_sha256'], 'exact original immutable manifest')
    old = json.loads(old_path.read_text())
    require(old['store'] == str(store) and old['project_root'] == str(store / 'project'),
            'historical generation owns this store/root')
    verify_files(immutable_files(old), store)
    native_path = Path(failed['simulation_receipt'])
    require(sha(native_path) == failed['simulation_receipt_sha256'], 'original native prerequisite receipt bytes')
    native = json.loads(native_path.read_text())
    require(native['status'] == 'passed' and native['store'] == str(store) and native['root'] == str(store / 'project') and
            native['manifest_sha256'] == failed['manifest_sha256'] and native['identities'] == failed['identities'] and
            native['attempts'] == failed['attempts'], 'same original native prerequisites across app recapture')
    for name, digest in old['asic_files'].items():
        require(sha(Path(old['inputs']['asic_generation']) / name) == digest, 'same installed ASIC bytes')
    collection = json.loads((failed_path.parent / 'report-collection.json').read_text())
    require(field(collection, 'state') == 'failed' and field(collection, 'attempt') == [] and
            field(collection, 'acceptance_requested') == 'false' and
            'Finalize requires an exact completed fresh physical execution' in str(field(collection, 'error')),
            'only the unallocated production synthesis-collection eligibility failure is recoverable')
    require(diagnosis['status'] == 'blocked_at_production_collection_gate' and
            diagnosis['receipt_hashes'][str(failed_path)] == descriptor['failed_receipt']['sha256'] and
            diagnosis['receipt_hashes'][str(summary_path)] == descriptor['resource_summary']['sha256'] and
            diagnosis['receipt_hashes'][str(outputs_path)] == descriptor['tool_outputs']['sha256'] and
            diagnosis['receipt_hashes'][str(failed_path.parent / 'report-collection.json')] ==
            sha(failed_path.parent / 'report-collection.json'), 'diagnosis binds exact failure, collection and proof files')
    require(summary['completed'] is True and summary['seen_flow'] is True and
            summary['runtime_ceiling_established'] is True and summary['store'] == str(store) and
            summary['manifest_sha256'] == failed['manifest_sha256'] and
            summary['cap_receipt_sha256'] == failed['resource_admission']['cap_receipt_sha256'] and
            summary['cap_binding']['store'] == str(store) and
            summary['cap_binding']['manifest_sha256'] == failed['manifest_sha256'] and
            summary['cap_binding']['asic_generation'] == old['inputs']['asic_generation'] and
            summary['cap_binding']['asic_receipt_sha256'] == old['asic_receipt_sha256'],
            'passing original resource proof bound to original execution capture/provider')
    execution_path = Path(failed['execution']['path'])
    raw = execution_path.read_bytes()
    require(execution_path.resolve() == execution_path and execution_path.is_relative_to(store) and
            hashlib.sha256(raw).hexdigest() == failed['execution']['sha256'] and
            raw == (failed_path.parent / 'execution-original.json').read_bytes(), 'exact successful original execution bytes')
    execution = json.loads(raw)
    require(execution['status'] == 'completed' and execution['exit_code'] == 0 and
            execution['plan']['stages'] == ['synthesis'] and execution['plan']['initial_boundary'] is None and
            len(execution['artifacts']) == len(execution['occurrences']) == 1 and
            execution['artifacts'][0]['boundary'] == 'synthesis' and
            execution['occurrences'][0]['status'] == 'completed' and execution['occurrences'][0]['exit_code'] == 0,
            'one completed fresh synthesis only; no hardware retry or physical extension')
    require(execution['attempt_id'] == field(failed['reference'], 'id') == diagnosis['synthesis']['run_id'] and
            diagnosis['synthesis']['execution_sha256'] == failed['execution']['sha256'], 'same diagnosed successful run')
    workflow = json.loads((failed_path.parent / 'workflow.json').read_text())
    require(field(workflow, 'phase') == 'Completed' and field(workflow, 'id') == failed['workflow_id'] and
            field(workflow, 'run') == [failed['reference']] and field(collection, 'run') == failed['reference'] and
            field(collection, 'execution_file') == str(execution_path), 'same completed workflow/run/failed collection')
    intent = field(workflow, 'intent')
    require(dict(field(intent, 'selection')) == dict(flow='standard', profile='balanced', endpoint='synthesis', assignments=[]) and
            field(intent, 'elaboration_only') == 'false', 'exact original standard/balanced synthesis intent')
    verify_files(json.loads((failed_path.parent / 'bundle-files.json').read_text()), store)
    verify_files(outputs, store)
    for key in ('daemon', 'client'):
        app = descriptor['new_apps'][key]
        app_path = Path(app['path'])
        require(app_path.resolve() == app_path and (not check_app_sources or sha(app_path) == app['sha256']),
                'reviewed replacement ' + key + ' bytes')
    require(descriptor['new_apps']['daemon']['sha256'] != old['apps']['daemon']['sha256'],
            'backend correction requires a new daemon identity')
    build = Path(descriptor['wb_build_root'])
    require(build.is_absolute() and build.resolve() == build and
            all(Path(descriptor['new_apps'][key]['path']) == build / target for key, target in
                (('daemon', 'default/daemon/main.exe'), ('client', 'default/terminal/main.exe'))),
            'replacement app pair belongs to explicit build root')
    return dict(descriptor=descriptor, descriptor_path=str(path), descriptor_sha256=hashlib.sha256(descriptor_raw).hexdigest(),
                failed=failed, failed_path=str(failed_path), old_manifest=old, old_manifest_path=str(old_path),
                workflow=workflow, collection=collection, outputs=outputs)


def validate_transition(old, new, store):
    require(old['store'] == new['store'] == str(store) and old['project_root'] == new['project_root'],
            'recapture preserves exact store/project root')
    require(old['generation'] != new['generation'], 'recapture creates a new immutable generation')
    for key in ('source_layout', 'source_files', 'source_roots', 'suite_sources', 'asic_files', 'asic_receipt_sha256'):
        require(old[key] == new[key], 'app recapture preserves ' + key)
    for key in ('asic_generation', 'toolchain', 'git_dir', 'git', 'dune', 'python'):
        require(old['inputs'][key] == new['inputs'][key], 'app recapture preserves dependency/tool input ' + key)
    for manifest in (old, new):
        require(manifest['environment'].get('HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT') == '6' and
                manifest['max_jobs'] in (1, 2), 'preserve explicit task-limit6 and max2')
    sdk = lambda m: {k:v for k,v in m['captured_files'].items() if k.startswith('sdk/')}
    require(bool(sdk(old)) and sdk(old) == sdk(new), 'same exact SDK inventory')
    for key in ('config_files', 'environment', 'provider_command', 'provider_commands', 'git_context'):
        require(old[key] == new[key], 'app-only recapture preserves exact history scope: ' + key)
    recapture = new.get('app_recapture', {})
    require(recapture.get('previous_generation') == old['generation'] and
            recapture.get('previous_manifest_sha256') == sha(Path(old['generation']) / 'manifest.json') and
            recapture.get('provider_config_environment_preserved') is True,
            'supported launcher app-only recapture receipt binds original generation')


def implementation_ids(snapshot):
    return dict(workflows=sorted(field(w, 'id') for w in field(snapshot, 'workflows')),
                runs=sorted(json.dumps(field(r, 'run'), sort_keys=True) for r in field(snapshot, 'runs')),
                launches=sorted(field(v, 'key') for v in field(snapshot, 'launches')))


def fresh_collection(snapshot, baseline, reference):
    current = field(snapshot, 'finalizations')
    old = {field(v, 'key'): v for v in baseline}
    require(all(next((v for v in current if field(v, 'key') == key), None) == value
                for key, value in old.items()), 'retained failed collection history unchanged')
    fresh = [v for v in current if field(v, 'key') not in old]
    require(len(fresh) <= 1, 'at most one new collection; never a collection retry')
    if fresh:
        require(field(fresh[0], 'run') == reference and field(fresh[0], 'acceptance_requested') == 'false',
                'new collection bound to exact original run without acceptance')
    return fresh[0] if fresh else None
