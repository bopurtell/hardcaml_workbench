#!/usr/bin/env python3
"""Resource observer negative controls. No Docker, EDA, Dune or retained-state writes."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('developer-workflow-resources.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class Controls(unittest.TestCase):
    def setUp(self):
        self.store = Path('/tmp/opencode/resource-control-store')
        self.c = dict(Image=r.IMAGE, Name='/hardcaml-asic-execution-' + 'a' * 32,
            HostConfig=dict(NanoCpus=6_000_000_000, CpuQuota=0),
            Config=dict(Env=[key + '=6' for key in r.LIMIT_ENV]),
            Mounts=[dict(Type='bind', Source=str(self.store / 'work'), RW=True),
                    dict(Type='bind', Source='/readonly/pdk', RW=False)])

    def test_six_is_admitted(self):
        self.assertEqual(r.validate_container(self.c, self.store), [])

    def test_quota_two_is_not_relabelled_six(self):
        self.c['HostConfig']['NanoCpus'] = 2_000_000_000
        self.assertTrue(r.validate_container(self.c, self.store))

    def test_quota_expansion_and_unlimited_reject(self):
        for cpus in (0, 7_000_000_000, 20_000_000_000):
            with self.subTest(cpus=cpus):
                self.c['HostConfig']['NanoCpus'] = cpus
                self.assertTrue(r.validate_container(self.c, self.store))

    def test_missing_duplicate_or_expanded_environment_reject(self):
        for env in ([], ['OMP_NUM_THREADS=20'], self.c['Config']['Env'] + ['OMP_NUM_THREADS=6']):
            with self.subTest(env=env):
                c = copy.deepcopy(self.c)
                c['Config']['Env'] = env
                self.assertTrue(r.validate_container(c, self.store))

    def test_owner_or_sibling_mount_is_not_owned(self):
        for root in ('/home/wayne/devel/jane/hardcaml_asic_example', str(self.store) + '-other'):
            self.c['Mounts'][0]['Source'] = root
            self.assertFalse(r.owned(self.c, self.store))
            self.assertTrue(r.validate_container(self.c, self.store))

    def test_external_writable_mount_rejects(self):
        self.c['Mounts'][1]['RW'] = True
        self.assertTrue(r.validate_container(self.c, self.store))

    def test_unknown_image_or_name_rejects(self):
        for field, value in [('Image', 'wrong'), ('Name', '/owner-daemon')]:
            c = copy.deepcopy(self.c)
            c[field] = value
            self.assertTrue(r.validate_container(c, self.store))

    def test_prompt_tool_mentions_are_not_worker_processes(self):
        rows = {1: dict(pid=1, ppid=0, argv=['opencode', 'run dune yosys build'], comm='opencode'),
                2: dict(pid=2, ppid=1, argv=['/bin/dune', 'build', '-j2'], comm='dune'),
                3: dict(pid=3, ppid=2, argv=['/bin/ocamlopt', 'x.ml'], comm='ocamlopt')}
        self.assertEqual([p['pid'] for p in r.workers(rows)], [2, 3])
        self.assertEqual(r.descendants(rows, 2), {2, 3})
        self.assertEqual(r.workers(rows, r.descendants(rows, 2)), [])

    def test_native_limits_and_nix_wrappers(self):
        self.assertEqual(r.executable_name('/nix/store/x/bin/.yosys-wrapped'), 'yosys')
        self.assertEqual(r.native_limits(['sta', '-threads', '1', '-exit']), [])
        self.assertEqual(r.native_limits(['yosys', '-y', 'synthesize.py']), [])
        for argv in (['sta', '-exit'], ['sta', '-threads', 'max'], ['yosys', '-j20'],
                     ['verilator', '--threads=20'], ['abc', '--jobs', '0']):
            with self.subTest(argv=argv):
                self.assertTrue(r.native_limits(argv))


if __name__ == '__main__':
    unittest.main()
