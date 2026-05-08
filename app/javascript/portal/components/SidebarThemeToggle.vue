<script>
import { directive as onClickaway } from 'vue3-click-away';

const TRIGGER_LABEL = 'Theme';

const OPTIONS = [
  { value: 'system', label: 'System', icon: 'i-lucide-monitor' },
  { value: 'light', label: 'Light', icon: 'i-lucide-sun' },
  { value: 'dark', label: 'Dark', icon: 'i-lucide-moon' },
];

export default {
  directives: { onClickaway },
  data() {
    return {
      mode: 'system',
      systemPrefersDark: false,
      open: false,
      options: OPTIONS,
      triggerLabel: TRIGGER_LABEL,
    };
  },
  computed: {
    triggerIcon() {
      const opt = OPTIONS.find(o => o.value === this.mode);
      return opt ? opt.icon : 'i-lucide-monitor';
    },
    isDarkActive() {
      if (this.mode === 'dark') return true;
      if (this.mode === 'light') return false;
      return this.systemPrefersDark;
    },
  },
  mounted() {
    try {
      const stored = localStorage.theme;
      this.mode = stored === 'dark' || stored === 'light' ? stored : 'system';
    } catch (e) {
      this.mode = 'system';
    }
    if (window.matchMedia) {
      this.media = window.matchMedia('(prefers-color-scheme: dark)');
      this.systemPrefersDark = this.media.matches;
      this.media.addEventListener('change', this.onSystemChange);
    }
    this.applyTheme();
  },
  unmounted() {
    if (this.media)
      this.media.removeEventListener('change', this.onSystemChange);
  },
  methods: {
    onSystemChange(e) {
      this.systemPrefersDark = e.matches;
      if (this.mode === 'system') this.applyTheme();
    },
    applyTheme() {
      const dark = this.isDarkActive;
      document.documentElement.classList.remove('dark', 'light');
      document.documentElement.classList.add(dark ? 'dark' : 'light');
    },
    select(value) {
      this.mode = value;
      try {
        if (value === 'system') localStorage.removeItem('theme');
        else localStorage.theme = value;
      } catch (e) {
        /* no-op */
      }
      this.applyTheme();
      this.open = false;
    },
    toggle() {
      this.open = !this.open;
    },
    close() {
      this.open = false;
    },
  },
};
</script>

<template>
  <div v-on-clickaway="close" class="relative">
    <button
      type="button"
      class="flex items-center justify-center w-9 h-9 text-n-slate-11 hover:text-n-slate-12 hover:bg-n-alpha-2 rounded-lg transition"
      :aria-label="triggerLabel"
      :aria-expanded="open"
      @click="toggle"
    >
      <span class="size-4" :class="[triggerIcon]" aria-hidden="true" />
    </button>
    <div
      v-if="open"
      class="absolute right-0 top-full mt-2 bg-n-slate-1 border border-solid border-n-weak rounded-lg shadow-lg p-1 min-w-36 z-50"
    >
      <button
        v-for="opt in options"
        :key="opt.value"
        type="button"
        class="w-full flex items-center justify-between gap-2.5 px-2.5 py-2 text-sm rounded-md transition"
        :class="[
          mode === opt.value
            ? 'bg-n-portal-soft text-n-portal'
            : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12',
        ]"
        @click="select(opt.value)"
      >
        <span class="flex items-center gap-2">
          <span class="size-4" :class="[opt.icon]" aria-hidden="true" />
          {{ opt.label }}
        </span>
        <span
          v-if="mode === opt.value"
          class="i-lucide-check size-3.5"
          aria-hidden="true"
        />
      </button>
    </div>
  </div>
</template>
