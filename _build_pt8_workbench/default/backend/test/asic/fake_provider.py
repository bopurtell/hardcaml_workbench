#!/usr/bin/env python3
"""Injected public-boundary fixture: no EDA, provider imports, or shell."""
import json
import hashlib
import os
import signal
import sys
import time

args = sys.argv[1:]
root = os.getcwd()
with open(os.path.join(root, 'calls'), 'a') as out:
    out.write(json.dumps(args) + '\n')


def option(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default


def emit(value):
    print(json.dumps(value), flush=True)


def envelope(contract, version=1, **fields):
    return dict(contract='hardcaml-asic.' + contract, schema_version=version, **fields)


def plan():
    return envelope('methodology-plan', plan_identity='a' * 64,
                    bundle_identity='b' * 64)


if args == ['lifecycle-exit']:
    sys.exit(0)
elif args[:1] in [['lifecycle-wait'], ['lifecycle-output'], ['lifecycle-malformed'], ['lifecycle-cancel']]:
    mode = args[0]

    def stop_fixture(_signal, _frame):
        with open(os.path.join(root, mode + '-terminated'), 'w') as out:
            out.write('owned process received SIGTERM')
        # Do not flush a buffered oversized stdout record during failure cleanup.
        os._exit(130)

    signal.signal(signal.SIGTERM, stop_fixture)
    if mode == 'lifecycle-malformed':
        print('not-json', flush=True)
    else:
        emit(dict(ready=True))
    if mode == 'lifecycle-output':
        # No newline: exercise the per-record budget, not JSON parser behaviour.
        for _ in range(9):
            sys.stdout.write('x' * (1024 * 1024))
            sys.stdout.flush()
    time.sleep(30)
elif args == ['--version', '--json']:
    emit(dict(cli_contract=dict(version=4, capabilities=dict(
        namedflow1=True, timing_stage1=os.path.exists('timing-capability')))))
elif args[:2] == ['flow', 'list']:
    if os.path.exists('fail-discovery'):
        sys.exit(1)
    time.sleep(0.1)
    with open(os.path.join(os.path.dirname(__file__), 'production_flow_list.json')) as src:
        value = json.load(src)
    if os.path.exists('invalid-discovery'):
        value['declaration']['default']['profile'] = 'missing'
    if os.path.exists('timing-catalog'):
        for entry in value['declaration']['entries']:
            entry['methodology']['endpoints'].insert(-1, 'timing')
    emit(value)
elif args[:2] == ['flow', 'describe']:
    emit(envelope('flow-describe', entry=dict(
        methodology=dict(id=option('--flow'), endpoints=(
            ['synthesis', 'timing', 'signoff'] if os.path.exists('timing-catalog')
            else ['synthesis', 'signoff'])),
        profiles=[dict(id='balanced'), dict(id='synth_delay')]),
        capabilities=dict(stage_selection='complete-prefix-through-declared-endpoint')))
elif args[:2] == ['flow', 'plan']:
    emit(plan())
elif args[:1] == ['stages']:
    with open(option('--methodology-plan')) as src:
        frozen = json.load(src)
    assert option('--expected-plan-identity') == frozen['plan_identity']
    profile = frozen['fixture_profile']
    endpoint = frozen['fixture_endpoint']
    if endpoint == 'timing':
        profile += '-timing'
    attempt = os.path.join(root, 'attempt-' + profile)
    os.makedirs(attempt, exist_ok=True)
    stream = 'stream-' + profile

    def terminate(_signal, _frame):
        with open(os.path.join(attempt, 'terminated'), 'w') as out:
            out.write('owned launcher received SIGTERM')
        sys.exit(130)

    signal.signal(signal.SIGTERM, terminate)
    emit(envelope('stage-observation', event='observation_allocated',
                  attempt=attempt, stream_id=stream))
    if profile.startswith('exit-race'):
        for _ in range(500):
            if os.path.exists(os.path.join(attempt, 'in-flight')):
                break
            time.sleep(0.01)
        else:
            sys.exit(99)
        with open(os.path.join(attempt, 'done'), 'w') as out:
            out.write('terminal records published before failing exit')
        sys.exit(2)
    time.sleep(0.6 if not os.path.exists('hold') else 30)
    with open(os.path.join(attempt, 'done'), 'w') as out:
        out.write('done')
    if endpoint == 'timing':
        stages = ['synthesis', 'floorplan', 'placement', 'cts', 'routing', 'timing']
        execution = dict(attempt_id=stream, status='completed', exit_code=0,
                         plan=dict(schema_version=4, initial_boundary=None, stages=stages),
                         artifacts=[], occurrences=[dict(
                             occurrence_id=stream + '/implementation.' + stage,
                             action_key='implementation.' + stage, status='completed',
                             exit_code=0, duration_seconds=1.0, best_effort=False,
                             verdict=None) for stage in stages])
        method = envelope('historical-methodology', state='recorded',
                          plan_identity='a' * 64, bundle_identity='b' * 64,
                          reference=dict(attempt_id=stream))
        with open(os.path.join(attempt, 'execution.json'), 'w') as out:
            json.dump(execution, out)
        with open(os.path.join(attempt, 'observation.json'), 'w') as out:
            json.dump(envelope('stage-observation', 2, stream_id=stream, cursor=0,
                               writer_active=False, observation_status='final',
                               state=dict(execution, outcome=dict(status='completed', exit_code=0)),
                               methodology=method, execution_file=os.path.join(attempt, 'execution.json')), out)
    emit(envelope('stage-observation', event='observation_terminal',
                  execution_file=os.path.join(attempt, 'execution.json')))
elif args[:2] == ['observation', 'read-updates']:
    stage_fixture = os.path.join(args[2], 'observation.json')
    cursor = 0
    if os.path.basename(args[2]).startswith('attempt-exit-race'):
        cursor = 2 if os.path.exists(os.path.join(args[2], 'done')) else 0
    if os.path.exists(stage_fixture):
        with open(stage_fixture) as src:
            cursor = json.load(src)['cursor']
    emit(envelope('stage-observation', 2, stream_id=option('--stream-id'),
                  after=int(option('--after')), cursor=cursor, events=[]))
elif args[:2] == ['observation', 'inspect']:
    attempt = args[2]
    stage_fixture = os.path.join(attempt, 'observation.json')
    if os.path.exists(stage_fixture):
        with open(stage_fixture) as src:
            emit(json.load(src))
        sys.exit(0)
    stream = 'stream-' + os.path.basename(attempt).removeprefix('attempt-')
    done = os.path.exists(os.path.join(attempt, 'done'))
    profile = os.path.basename(attempt).removeprefix('attempt-')
    if profile.startswith('exit-race'):
        recovered = os.path.exists('race-recover')
        if done and profile == 'exit-race-unavailable' and not recovered:
            print('fixture terminal inspection unavailable', file=sys.stderr)
            sys.exit(3)
        final = done and (profile != 'exit-race-active' or recovered)
        value = envelope('stage-observation', 2, stream_id=stream,
                         cursor=2 if done else 0,
                         writer_active=not final,
                         observation_status='final' if final else 'active',
                         state=dict(outcome=dict(status='failed', exit_code=2) if final else None),
                         execution_file=os.path.join(attempt, 'execution.json') if final else None,
                         methodology=envelope('historical-methodology', state='pending',
                             launch=dict(attempt_id=stream, expected_plan_identity='a' * 64)),
                         stage_plan=envelope('stage-plan', stages=[dict(
                             id='synthesis', name='Synthesis', requested=True,
                             status='failed' if final else 'running', action=None,
                             reason='recorded provider outcome')]))
        if not done:
            seen = os.path.join(attempt, 'active-observed')
            if os.path.exists(seen):
                # First publish Running, then keep a subsequent read in flight at EOF.
                with open(os.path.join(attempt, 'in-flight'), 'w') as out:
                    out.write('inspection in flight')
                time.sleep(0.8)
            else:
                with open(seen, 'w') as out:
                    out.write('initial active inspection')
        emit(value)
        sys.exit(0)
    missing = os.path.exists('missing')
    method = envelope('historical-methodology', state='recorded' if done else 'pending',
                      plan_identity='a' * 64, bundle_identity='b' * 64,
                      reference=dict(attempt_id=stream),
                      launch=dict(attempt_id=stream, expected_plan_identity='a' * 64))
    emit(envelope('stage-observation', 2, stream_id=stream, cursor=0,
                  writer_active=not done, observation_status='final' if done else 'active',
                  state=dict(outcome=dict(status='completed', exit_code=0) if done else None),
                  methodology=method,
                  execution_file=os.path.join(attempt, 'execution.json') if done and not missing else None))
elif args[:1] == ['report']:
    attempt = os.path.dirname(args[1])
    profile = os.path.basename(attempt).removeprefix('attempt-')
    stream = 'stream-' + profile
    if profile.endswith('-timing'):
        with open(args[1]) as src:
            execution = json.load(src)
        emit(envelope('report', execution=execution, checkpoints=[],
                      completion=dict(physical='partial'), acceptance='not_evaluated',
                      methodology=envelope('historical-methodology', state='recorded',
                          plan_identity='a' * 64, bundle_identity='b' * 64,
                          reference=dict(attempt_id=stream))))
        sys.exit(0)
    count = 50 if profile == 'balanced' else 73
    if os.path.exists('revision'):
        count += 1
    boundary = 'signoff' if profile == 'terminal' else 'synthesis'
    reference = dict(path=attempt, boundary=boundary, identity=str(count))
    references = [reference]
    if profile == 'terminal':
        stages = ['synthesis', 'floorplan', 'placement', 'cts', 'routing', 'signoff']
        if os.path.exists('seven-stage-finalization'):
            stages.insert(-1, 'timing')
        references = [dict(path=os.path.join(attempt, stage) if stage != 'signoff' else attempt,
                           boundary=stage, identity=str(count))
                      for stage in stages]
    methodology_reference = dict(attempt_id=stream)
    if profile == 'terminal':
        snapshot_path = os.path.join(attempt, 'methodology-plan.json')
        snapshot_bytes = json.dumps(envelope(
            'methodology-plan', plan_identity='a' * 64, bundle_identity='b' * 64,
            configuration_bytes=json.dumps(dict(CLOCK_PORT='clk', CLOCK_PERIOD=20.0)))).encode()
        if not os.path.exists(snapshot_path):
            with open(snapshot_path, 'wb') as out:
                out.write(snapshot_bytes)
        methodology_reference.update(snapshot_path=snapshot_path,
                                     snapshot_sha256=hashlib.sha256(snapshot_bytes).hexdigest(),
                                     plan_identity='a' * 64, bundle_identity='b' * 64)
    execution = dict(attempt_id=stream, status='completed', artifacts=references,
                     occurrences=[dict(action_key='implementation.' + boundary,
                                        status='completed', exit_code=0)])
    if profile.startswith('exit-race'):
        execution.update(status='failed', exit_code=2,
                         occurrences=[dict(action_key='implementation.synthesis',
                                           status='failed', exit_code=2)])
    if profile == 'terminal':
        stages = [ref['boundary'] for ref in references]
        execution.update(exit_code=0, plan=dict(schema_version=(4 if os.path.exists('seven-stage-finalization') else 3), initial_boundary=None, stages=stages),
                         occurrences=[dict(action_key='implementation.' + stage,
                                           occurrence_id=stream + '/implementation.' + stage,
                                           status='completed', exit_code=0) for stage in stages])
        if os.path.exists('finalize-resumed'):
            execution['plan']['initial_boundary'] = 'synthesis'
    with open(args[1], 'w') as out:
        json.dump(execution, out)
    emit(envelope('report', execution=execution,
                  completion=dict(physical='full' if boundary == 'signoff' else 'synthesis'),
                  acceptance='not_evaluated',
                  methodology=envelope('historical-methodology', state='recorded',
                                       plan_identity='a' * 64, bundle_identity='b' * 64,
                                       reference=methodology_reference),
                  checkpoints=[dict(reference=checkpoint_reference,
                                    metric_origin=dict(scope='boundary_snapshot'),
                                    metrics=[dict(raw_key=key, availability='available', value=value, unit=unit,
                                                  source=dict(path=os.path.join(checkpoint_reference['path'], 'segment.json'),
                                                              field='metrics.' + key,
                                                              raw=dict(availability='available', value=value)))
                                             for key, value, unit in [
                                                  ('design__instance__count', checkpoint_count, 'cells'),
                                                 ('design__instance__area', 13041.6048, 'µm²'),
                                                 ('design__lint_warning__count', 2, 'count'),
                                                 ('synthesis__check_error__count', 0, 'count')]],
                                    supplementary=[dict(mapped_cell_types={'cell': checkpoint_count})])
                               for checkpoint_reference, checkpoint_count in
                               [(ref, count if ref['boundary'] == 'synthesis' else count + 1000)
                                for ref in references]]))
elif args[:1] == ['finalize']:
    if os.path.exists('finalize-no-allocation'):
        print('fixture allocation failure', file=sys.stderr)
        sys.exit(2)
    if os.path.exists('finalize-late'):
        time.sleep(0.4)
    store = option('--operation-store')
    attempt = os.path.join(store, 'operation-' + str(time.time_ns()))
    os.makedirs(attempt)
    operation_id = os.path.basename(attempt)
    execution_file = args[1]
    with open(execution_file, 'rb') as src:
        execution_bytes = src.read()
    execution = json.loads(execution_bytes)
    request = dict(execution=execution_file, accept='--accept' in args)
    for name in ['support_tools', 'precheck_python', 'testbench', 'testbench_top', 'replay_trace']:
        request[name] = option('--' + name.replace('_', '-'))
    receipt = envelope('segment-finalization', attempt_id=operation_id, status='running',
                       phase='validation', ended_at=None, exit_code=None, request=request,
                       acceptance='not_evaluated', external_postcheck='not_evaluated', results=None,
                       execution=dict(path=execution_file, sha256=hashlib.sha256(execution_bytes).hexdigest(),
                                      attempt_id=execution['attempt_id']),
                       selected_checkpoints=execution['artifacts'],
                       evidence_context=dict(build_identity='b' * 64))

    def save_receipt():
        temporary = os.path.join(attempt, 'operation.tmp')
        with open(temporary, 'w') as out:
            json.dump(receipt, out)
        os.replace(temporary, os.path.join(attempt, 'operation.json'))

    def stop_finalization(_signal, _frame):
        receipt.update(status='interrupted', ended_at='recorded', exit_code=143)
        save_receipt()
        with open(os.path.join(attempt, 'terminated'), 'w') as out:
            out.write('owned finalize received SIGTERM')
        sys.exit(143)

    signal.signal(signal.SIGTERM, stop_finalization)
    save_receipt()
    emit(envelope('segment-finalization', event='allocated', attempt=attempt, attempt_id=operation_id))
    receipt['phase'] = 'external_postcheck' if request['accept'] else 'collection'
    save_receipt()
    time.sleep(30 if os.path.exists('finalize-hold') else 0.3)
    failed = request['accept']
    results = dict(schema_version=1, run_id=operation_id, build_identity='b' * 64,
                   provenance=dict(contract='hardcaml-asic.segment-finalization',
                                   operation=os.path.join(attempt, 'operation.json')),
                   metrics={}, checks={}, timing_goal='unknown')
    results_bytes = json.dumps(results).encode()
    results_file = os.path.join(attempt, 'results.json')
    with open(results_file, 'wb') as out:
        out.write(results_bytes)
    receipt.update(status='failed' if failed else 'completed', ended_at='recorded',
                   exit_code=1 if failed else 0, acceptance='fail' if failed else 'not_evaluated',
                   external_postcheck='failed' if failed else 'not_evaluated',
                   results=dict(path=results_file, sha256=hashlib.sha256(results_bytes).hexdigest()))
    save_receipt()
    emit(dict(receipt, attempt=attempt))
    sys.exit(receipt['exit_code'])
elif args[:1] == ['finalization-inspect']:
    if os.path.exists('finalize-inspect-fail'):
        print('fixture finalization inspection unavailable', file=sys.stderr)
        sys.exit(2)
    with open(os.path.join(args[1], 'operation.json')) as src:
        emit(json.load(src))
else:
    print('Unsupported fixture argv: ' + repr(args), file=sys.stderr)
    sys.exit(2)
