// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

const repo = 'https://github.com/staticwire/aurtomator';

export default defineConfig({
  site: 'https://staticwire.github.io',
  base: '/aurtomator',
  integrations: [
    mermaid(),
    starlight({
      title: 'aurtomator',
      description: 'Automated AUR package updates',
      logo: { light: './src/assets/lockup-light.svg', dark: './src/assets/lockup-dark.svg', alt: 'aurtomator', replacesTitle: true },
      favicon: '/favicon.svg',
      head: [
        { tag: 'link', attrs: { rel: 'icon', href: '/aurtomator/favicon-32.png', sizes: '32x32' } },
        { tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/aurtomator/apple-touch-icon.png' } },
      ],
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      components: { PageTitle: './src/components/PageTitle.astro' },
      plugins: [starlightLinksValidator(), starlightLlmsTxt()],
      sidebar: [
        { label: 'Start', items: ['overview', 'setup', 'add-a-package', 'gpg-signing'] },
        { label: 'Packages', items: ['package-yaml', 'strategies', 'supported-packages', 'custom-strategies'] },
        { label: 'Features', items: ['features/downgrades', 'features/update-alerts', 'features/asset-values', 'features/cooldown', 'features/missing-arches', 'features/issues', 'features/statistics', 'features/aurtomator-updates'] },
        { label: 'How it works', items: ['internals/update-process', 'internals/workflow'] },
        { label: 'Develop', items: ['develop/local-testing', 'develop/ci', { label: 'Contributing', link: `${repo}/blob/main/CONTRIBUTING.md` }] },
        { label: 'Help', items: ['help/troubleshooting', { label: 'Comparison with other tools', link: `${repo}#alternatives` }] },
        { label: 'Project', items: [{ label: 'Security policy', link: `${repo}/security/policy` }, { label: 'Releases', link: `${repo}/releases` }] },
      ],
    }),
  ],
});
