import esbuild from 'esbuild';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

await esbuild.build({
  entryPoints: [path.join(here, 'src/bridge.ts')],
  bundle: true,
  format: 'iife',
  target: 'es2022',
  outfile: path.join(here, '../Photos/Resources/WebBridge.js'),
  // userscript-manager global; in the webview the page window is the real window
  define: { unsafeWindow: 'window' },
  banner: { js: [
    '/* Generated from webbridge/ + third_party/gptk by tools/build-webbridge.sh. Do not edit.',
    ' * Contains code from Google Photos Toolkit, Copyright (c) 2024 xob0t,',
    ' * MIT License: https://github.com/xob0t/Google-Photos-Toolkit/blob/main/LICENSE',
    ' * Bridge sources Copyright (C) 2026 Jaroslav Sazma, GPL-3.0-or-later. */',
  ].join('\n') },
  // evaluateJavaScript needs a serializable completion value, not the iife's export object
  footer: { js: ';0;' },
  plugins: [
    {
      // the bundle must never pull in gptk's UI layer or its UI-driven core; a renamed
      // import that slips past the log shim fails the build instead of shipping DOM code
      name: 'forbid-gptk-ui',
      setup(build) {
        build.onLoad({ filter: /third_party[\/\\]gptk[\/\\]src[\/\\](ui[\/\\]|gptk-core)/ }, (args) => {
          throw new Error(`forbidden gptk module bundled: ${args.path}`);
        });
      },
    },
    {
      // gptk's api-utils logs through its DOM log panel; route those lines to the native side
      name: 'gptk-log-shim',
      setup(build) {
        build.onResolve({ filter: /ui\/logic\/log$/ }, () => ({ path: path.join(here, 'src/log-shim.ts') }));
      },
    },
  ],
});
console.log('WebBridge.js built');
