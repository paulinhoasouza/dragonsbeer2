import {build} from 'esbuild';
await build({entryPoints:['src/app.js'],bundle:true,minify:true,format:'esm',outfile:'public/app.js',target:'es2022'});
console.log('App pronto em public/. Configuração Supabase lida do Worker em tempo de execução.');
