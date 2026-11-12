// The images live in assets/ at the root, where the README reads them too.
// This script copies them here before each build; git ignores the copies.
import { copyFileSync, mkdirSync } from 'node:fs';

const from = (name) => new URL(`../../assets/${name}`, import.meta.url);
const to = (path) => new URL(`../${path}`, import.meta.url);

mkdirSync(to('src/assets/'), { recursive: true });
for (const name of ['lockup-light.svg', 'lockup-dark.svg', 'icon-light.svg', 'icon-dark.svg']) {
  copyFileSync(from(name), to(`src/assets/${name}`));
}
mkdirSync(to('public/demo/'), { recursive: true });
for (const name of ['favicon.svg', 'favicon-32.png', 'apple-touch-icon.png']) {
  copyFileSync(from(name), to(`public/${name}`));
}
// copyFileSync(from('demo/draft.gif'), to('public/demo/draft.gif'));
