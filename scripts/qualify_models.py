#!/usr/bin/env python3
"""Opt-in, sequential, resumable qualification of the app's actual offline worker."""
import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from functools import lru_cache
from importlib.metadata import distribution, version
from pathlib import Path


VARIANTS = {"3b": "seedvr2-3b-8bit", "7b": "seedvr2-7b-8bit", "7b-sharp": "seedvr2-7b-sharp-mlx-int8"}
CLASSES = ("portrait", "lettering", "texture", "compressed")


def arguments():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--bundle", type=Path, help="Use the runtime and worker inside this Refract.app")
    p.add_argument("--checkpoint", type=Path, help="Single-file SDXL safetensors checkpoint")
    p.add_argument("--models", type=Path, help="Directory containing the three named SeedVR2 packages")
    p.add_argument("--portrait", type=Path, required=True, help="A real, user-selected portrait fixture")
    p.add_argument("--inputs", type=Path, help="Optionally override each class with a file named portrait, lettering, texture or compressed")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--only", action="append", choices=["generate", *VARIANTS], help="Repeat to select stages; default is all")
    p.add_argument("--prepare", action="store_true", help="Prepare input images and a synthetic SDXL LoRA without inference")
    return p.parse_args()


def digest_now(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


digest_file = lru_cache(maxsize=None)(digest_now)


def signature(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def write_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    temp.replace(path)


def prepare(out, portrait, overrides):
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    import numpy as np
    from safetensors.numpy import save_file

    fixtures = out / 'fixtures'
    fixtures.mkdir(exist_ok=True)
    # These photographs ship with macOS. Each run remains local and records its chosen source files.
    pictures = Path('/Library/User Pictures')
    files = {'portrait': portrait, 'texture': pictures/'Nature/Leaf.heic',
             'lettering': pictures/'Flowers/Sunflower.heic', 'compressed': pictures/'Nature/Lightning.heic'}
    inputs = {}
    for name, source in files.items():
        if overrides:
            choices = sorted(overrides.glob(name + '.*'))
            if len(choices) > 1:
                raise ValueError(f'More than one fixture supplied for {name}')
            source = choices[0] if choices else source
        source = source.resolve(strict=True)
        if source.suffix.lower() in ('.heic', '.heif'):
            decoded = fixtures / (name + '-decoded.tiff')
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'tiff', str(source), '--out', str(decoded)],
                           stdout=subprocess.DEVNULL, check=True)
            opened = decoded
        else:
            opened = source
        with Image.open(opened) as im:
            image = ImageOps.fit(ImageOps.exif_transpose(im).convert('RGB'), (192, 192), method=Image.Resampling.LANCZOS)
        if name == 'lettering':
            draw = ImageDraw.Draw(image)
            font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 17)
            draw.rectangle((0, 124, 192, 192), fill='#e9edda')
            draw.text((8, 134), 'REFRACT   7B', fill='#1c3021', font=font)
            draw.text((8, 160), 'focus 1:2:3', fill='#334133', font=font)
        fixture = fixtures / (name + ('.jpg' if name == 'compressed' else '.png'))
        image.save(fixture, **({'quality': 15, 'subsampling': 2} if name == 'compressed' else {}))
        inputs[name] = fixture
        write_json(fixtures/(name+'.json'), {'source': str(source), 'source_sha256': digest_file(source), 'output': str(fixture)})
    with Image.open(inputs['texture']) as image:
        tiny = fixtures/'texture-96.png'
        image.resize((96, 96), Image.Resampling.LANCZOS).save(tiny)
        inputs['small'] = tiny
    rng = np.random.default_rng(1138)
    weights = {}
    for projection in ('to_k', 'to_v'):
        key = f'unet.down_blocks.1.attentions.0.transformer_blocks.0.attn2.{projection}'
        weights[key+'.lora_A.weight'] = rng.normal(0, .08, (4, 2048)).astype(np.float16)
        weights[key+'.lora_B.weight'] = rng.normal(0, .08, (640, 4)).astype(np.float16)
    adapter = fixtures/'qa-rank4.safetensors'
    # Safetensors serializes metadata map order nondeterministically. Keep the single existing fixture for resumes.
    if not adapter.exists():
        save_file(weights, adapter, metadata={'ss_base_model_version': 'sdxl_base_v1-0'})
    return inputs, adapter


class Usage(ctypes.Structure):
    # Darwin sys/resource.h, rusage_info_v0.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ('user', 'system', 'package_wakeups', 'interrupt_wakeups', 'pageins', 'wired', 'resident',
         'footprint', 'started', 'exited')]


@contextmanager
def measure(pid):
    getter = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pid_rusage
    stop = threading.Event()
    peak = {'sampled_peak_footprint_bytes': 0, 'samples': 0}

    def sample():
        usage = Usage()
        while not stop.is_set():
            if getter(pid, 0, ctypes.byref(usage)) == 0:
                peak['sampled_peak_footprint_bytes'] = max(peak['sampled_peak_footprint_bytes'], usage.footprint)
                peak['samples'] += 1
            stop.wait(.2)

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    try:
        yield peak
    finally:
        stop.set()
        thread.join()


class Suite:
    def __init__(self, resources, python, out):
        self.worker = resources/'Worker/worker.py'
        self.python = python
        self.out = out
        self.data = {}
        configs = self.worker.parent/'configs'/'sdxl'
        self.identity = dict(worker=digest_file(self.worker), python=sys.version,
                             adapters={p.name: digest_file(p) for p in sorted((self.worker.parent/'refract_models').glob('*.py'))},
                             sdxl_config=signature([(p.relative_to(configs).as_posix(), digest_file(p))
                                                   for p in sorted(configs.rglob('*')) if p.is_file()]),
                             mlx_wheels={p: [line[5:].strip() for line in distribution(p).read_text('WHEEL').splitlines()
                                             if line.startswith('Tag:')] for p in ('mlx','mlx-metal')},
                             packages={p: version(p) for p in ('torch', 'diffusers', 'mlx', 'mlx-gen', 'transformers', 'peft', 'safetensors')})
        for subdir in ('results', 'receipts', 'logs'):
            (out/subdir).mkdir(exist_ok=True)

    @contextmanager
    def session(self, group):
        env = dict(os.environ, HF_HOME=str(self.out/'offline-hf-cache'), HF_HUB_OFFLINE='1')
        with (self.out/'logs'/(group+'.log')).open('a') as diagnostics:
            child = subprocess.Popen([str(self.python), '-I', '-B', '-u', str(self.worker)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=diagnostics, text=True, env=env)
            try:
                yield child
            finally:
                child.stdin.close()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()

    def case(self, child, name, request, model_hash, *, rerun=False):
        from PIL import Image, ImageStat
        input_path = request.get('inputPath')
        stamp = signature([self.identity, request, model_hash, digest_file(Path(input_path)) if input_path else None,
                           [digest_file(Path(x['path'])) for x in request.get('loras', [])]])
        stem = name+'-'+stamp[:12]
        receipt, output = self.out/'receipts'/(stem+'.json'), self.out/'results'/(stem+'.png')
        if not rerun and receipt.is_file() and output.is_file():
            saved = json.loads(receipt.read_text())
            if saved.get('passed') and digest_file(output) == saved['file_sha256']:
                self.data[name] = saved
                print(f'{name}: resumed', flush=True)
                return
        with tempfile.TemporaryDirectory(dir=self.out) as temp:
            target = Path(temp)/'worker.png'
            job = dict(request, id=name, outputPath=str(target))
            print(f'{name}: running', flush=True)
            start = time.monotonic()
            events = []
            with measure(child.pid) as memory:
                child.stdin.write(json.dumps(job)+'\n')
                child.stdin.flush()
                for line in child.stdout:
                    event = json.loads(line)
                    if event.get('id') != name:
                        raise RuntimeError(f'Unexpected worker response {event}')
                    event['seconds'] = round(time.monotonic()-start, 3)
                    events.append(event)
                    if event['type'] in ('done', 'error'):
                        break
            elapsed = round(time.monotonic()-start, 3)
            record = dict(id=name, request=job, model_sha256=model_hash, runtime=self.identity,
                          seconds=elapsed, events=events, **memory, passed=False)
            write_json(receipt, record)
            if not events or events[-1]['type'] != 'done':
                raise RuntimeError(f'{name} failed: {events[-1] if events else child.poll()}')
            with Image.open(target) as image:
                image = image.convert('RGB')
                if image.size != (job['width'], job['height']) or max(ImageStat.Stat(image).stddev) < 1:
                    raise ValueError(f'{name} returned incorrect geometry or an effectively blank frame')
                record['pixel_sha256'] = hashlib.sha256(image.tobytes()).hexdigest()
            target.replace(output)
            record.update(passed=True, file=str(output), file_sha256=digest_now(output))
            write_json(receipt, record)
            self.data[name] = record
            print(f"{name}: {elapsed:.2f}s, sampled peak {memory['sampled_peak_footprint_bytes']/2**30:.2f} GiB", flush=True)


def contact_sheet(path, rows):
    from PIL import Image, ImageDraw, ImageFont, ImageOps
    cell, caption = 228, 28
    canvas = Image.new('RGB', (cell*max(map(len,rows)), (cell+caption)*len(rows)), '#181a1c')
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 14)
    for r, row in enumerate(rows):
        for c, (label, src) in enumerate(row):
            x, y = c*cell, r*(cell+caption)
            with Image.open(src) as image:
                tile = ImageOps.contain(image.convert('RGB'), (cell-4,cell-4), method=Image.Resampling.LANCZOS)
            canvas.paste(tile,(x+(cell-tile.width)//2, y+2))
            draw.text((x+5,y+cell+4), label, fill='white', font=font)
    canvas.save(path)


def qualify_generation(suite, checkpoint, adapter, inputs):
    import numpy as np
    from PIL import Image
    checkpoint = checkpoint.absolute()
    common = dict(operation='generate', modelPath=str(checkpoint), modelVariant='sdxl', width=512, height=512,
                  prompt='A portrait in a softly lit photography studio, detailed skin, natural colors, close-up.',
                  negativePrompt='', steps=8, guidance=5.0, seed=1642, strength=.6, sampler='DPM++ 2M', scheduler='Karras')
    jobs = [('base', {'loras': []}), ('active', {'loras': [{'path':str(adapter), 'scale':1.0}]}),
            ('zero', {'loras': [{'path':str(adapter), 'scale':0.0}]}), ('removed', {'loras':[]}),
            ('image-a', {'loras':[], 'inputPath':str(inputs['portrait'])}),
            ('image-b', {'loras':[], 'inputPath':str(inputs['texture'])})]
    # Adapter controls must share a live process even if a previous run was interrupted midsequence.
    proof_file = suite.out/'sdxl-proof.json'
    model_id = digest_file(checkpoint)
    sequence = signature([suite.identity, common, model_id, digest_file(adapter), jobs,
                          digest_file(inputs['portrait']), digest_file(inputs['texture'])])
    existing = json.loads(proof_file.read_text()) if proof_file.is_file() else {}
    reuse = existing.get('passed') and existing.get('sequence') == sequence and all(
        Path(f).exists() and digest_file(Path(f)) == h for f,h in existing.get('files',{}).items())
    with suite.session('generate') as child:
        for name, overrides in jobs:
            suite.case(child,'sdxl-'+name,common|overrides,model_id,rerun=not reuse)
    rows = {k: suite.data['sdxl-'+k] for k,_ in jobs}
    with Image.open(rows['base']['file']) as base, Image.open(rows['active']['file']) as active:
        delta = float(np.abs(np.array(base,dtype=np.int16)-np.array(active,dtype=np.int16)).mean())
    baseline = rows['base']['pixel_sha256']
    checks = {'active_changes_pixels': delta > 0, 'zero_matches_baseline': rows['zero']['pixel_sha256'] == baseline,
              'removed_matches_baseline': rows['removed']['pixel_sha256'] == baseline,
              'reference_changes_pixels': rows['image-a']['pixel_sha256'] != rows['image-b']['pixel_sha256']}
    passed = all(checks.values())
    write_json(proof_file, dict(sequence=sequence, checks=checks, mean_absolute_lora_difference=delta, passed=passed,
                                files={row['file']:row['file_sha256'] for row in rows.values()}))
    contact_sheet(suite.out/'sdxl-comparison.jpg', [[(k,rows[k]['file']) for k,_ in jobs[i:i+3]] for i in (0,3)])
    if not passed:
        raise RuntimeError(f'SDXL acceptance failed: {checks}')


def qualify_enhancement(suite, key, model, inputs):
    from PIL import Image
    model_id = signature([(p.relative_to(model).as_posix(), digest_file(p)) for p in sorted(model.rglob('*'))
                          if p.is_file() and '.cache' not in p.relative_to(model).parts and p.suffix in ('.safetensors','.json')])
    if not model.is_dir():
        raise ValueError(f'Missing SeedVR2 package {model}')
    rows = []
    with suite.session('seedvr2-'+key) as child:
        for name, scales in [*((name,(1,2)) for name in CLASSES), ('small',(3,4))]:
            src = inputs[name]
            with Image.open(src) as image:
                w,h = image.size
            row = [(f'{name} · source',src)]
            for scale in scales:
                case_name = f'seedvr2-{key}-{name}-{scale}x'
                req = dict(operation='enhance', modelPath=str(model), modelVariant='seedvr2-'+key, seed=1642,
                           inputPath=str(src), width=w*scale, height=h*scale, softness=0)
                suite.case(child,case_name,req,model_id)
                row.append((f'{key} · {scale}×',suite.data[case_name]['file']))
            rows.append(row)
    contact_sheet(suite.out/('seedvr2-'+key+'-comparison.jpg'),rows)


def main():
    args = arguments()
    resources = (args.bundle/'Contents/Resources' if args.bundle else args.root).resolve()
    python = resources / ('runtime' if args.bundle else '.runtime') / 'bin/python3.12'
    if Path(sys.executable).resolve() != python.resolve():
        os.execv(str(python), [str(python), '-I','-B',str(Path(__file__).resolve()),*sys.argv[1:]])
    args.out = args.out.resolve()
    args.out.mkdir(parents=True,exist_ok=True)
    inputs,adapter = prepare(args.out,args.portrait,args.inputs)
    if args.prepare:
        print(f'Fixtures ready in {adapter.parent}')
        return
    groups = args.only or ['generate',*VARIANTS]
    if 'generate' in groups and not args.checkpoint:
        raise SystemExit('--checkpoint is required for generation qualification')
    if any(group in VARIANTS for group in groups) and not args.models:
        raise SystemExit('--models is required for enhancement qualification')
    suite = Suite(resources,python,args.out)
    summary_path = args.out/'summary.json'
    prior = json.loads(summary_path.read_text()) if summary_path.is_file() else {}
    if prior.get('runtime') != suite.identity:
        prior = {}
    finished = set(prior.get('completed_groups', []))
    failures = prior.get('failures', {})
    records = prior.get('records', {})
    for group in groups:
        try:
            if group == 'generate':
                qualify_generation(suite,args.checkpoint,adapter,inputs)
            else:
                qualify_enhancement(suite,group,(args.models/VARIANTS[group]).resolve(),inputs)
            finished.add(group)
            failures.pop(group,None)
        except Exception as e:
            finished.discard(group)
            failures[group]=str(e)
            print(f'{group} failed: {e}',file=sys.stderr,flush=True)
        records.update(suite.data)
        write_json(summary_path,dict(runtime=suite.identity,completed_groups=sorted(finished),failures=failures,
                                    records=records,visual_review='pending'))
    if any(group in failures for group in groups):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
