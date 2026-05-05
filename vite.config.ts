import { defineConfig } from 'vite';
import ruby from 'vite-plugin-ruby';
import vue from '@vitejs/plugin-vue';
import { aliases, vueOptions } from './vite.shared';

export default defineConfig({
  plugins: [ruby(), vue(vueOptions)],
  resolve: { alias: aliases },
});
