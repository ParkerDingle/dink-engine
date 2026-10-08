// Connector to the trained shot-value model (ml/ → public/models/*.onnx).
// The model scores every candidate shot for a situation; the game uses those scores for grades,
// the eval map and AI shot choice. If the model or WebAssembly isn't available, the rule engine is used.
import type { Scorer } from '../sim/match';
import type { EngineState, ShotOption } from './rules';
import { featuresFor, FEATURE_VERSION, N_FEATURES } from './features';
import { fetchBinary } from '../fetchBinary';

export interface ModelCard {
  file: string; feature_version: string; trained_on: string; rows: number; auc: number; log_loss: number;
  created: string; source: string;
}

export async function loadModel(baseUrl: string): Promise<{ scorer: Scorer; card: ModelCard } | null> {
  try {
    const res = await fetch(new URL('models/model_card.json', baseUrl));
    if (!res.ok) return null;
    const card = (await res.json()) as ModelCard;
    if (card.feature_version !== FEATURE_VERSION) { console.warn(`Model expects ${card.feature_version}, game sends ${FEATURE_VERSION}`); return null; }
    const ort = await import('onnxruntime-web/wasm');
    ort.env.wasm.numThreads = 1;
    const bytes = new Uint8Array(await fetchBinary(new URL('models/' + card.file, baseUrl).href));
    const session = await ort.InferenceSession.create(bytes, { executionProviders: ['wasm'] });
    const input = session.inputNames[0];
    const output = session.outputNames.includes('probabilities') ? 'probabilities' : session.outputNames[session.outputNames.length - 1];
    let queue: Promise<unknown> = Promise.resolve();
    const scorer: Scorer = {
      score(state: EngineState, options: ShotOption[]) {
        // onnxruntime-web sessions run one inference at a time, so calls are queued
        const job = queue.then(async () => {
          if (!options.length) return options;
          const n = options.length, data = new Float32Array(n * N_FEATURES);
          options.forEach((o, k) => data.set(featuresFor(state, o.type, o.target), k * N_FEATURES));
          const out = await session.run({ [input]: new ort.Tensor('float32', data, [n, N_FEATURES]) });
          const probs = out[output].data as Float32Array;
          const cols = probs.length / n;
          return options.map((o, k) => ({ ...o, P: probs[k * cols + (cols - 1)] })).sort((a, b) => b.P - a.P);
        });
        queue = job.catch(() => null);
        return job as Promise<ShotOption[]>;
      },
    };
    return { scorer, card };
  } catch (e) {
    console.warn('Trained model not loaded, using the rule engine', e);
    return null;
  }
}
