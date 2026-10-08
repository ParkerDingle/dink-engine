// Writes ml/tests/fixtures/feature_parity.json so the Python feature code is tested against this one.
import { writeFileSync } from 'node:fs';
import { buildFixture } from '../tests/fixture';
writeFileSync('../ml/tests/fixtures/feature_parity.json', JSON.stringify(buildFixture(), null, 1));
console.log('wrote feature parity fixture');
