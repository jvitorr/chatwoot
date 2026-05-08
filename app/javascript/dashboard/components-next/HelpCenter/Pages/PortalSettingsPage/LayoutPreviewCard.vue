<script setup>
defineProps({
  active: { type: Boolean, default: false },
  title: { type: String, default: '' },
  description: { type: String, default: '' },
  name: { type: String, required: true },
  value: { type: String, required: true },
});
defineEmits(['select']);
</script>

<template>
  <button
    type="button"
    class="flex flex-col gap-4 w-full h-full p-4 rounded-md border border-solid text-left transition"
    :class="{
      'border-n-brand ring-1 ring-n-brand': active,
      'border-n-slate-5 dark:border-n-slate-6 hover:border-n-slate-7': !active,
    }"
    @click="$emit('select', value)"
  >
    <div class="flex flex-col gap-2 items-center w-full rounded-t-[5px]">
      <div class="grid grid-cols-[1fr_auto] items-center w-full gap-1">
        <div class="overflow-hidden text-heading-2 text-n-slate-12 text-start">
          <span class="block truncate">{{ title }}</span>
        </div>
        <input
          :checked="active"
          type="radio"
          :name="name"
          :value="value"
          class="shadow cursor-pointer grid place-items-center border-2 border-n-strong appearance-none rounded-full w-5 h-5 checked:bg-n-brand before:content-[''] before:bg-n-brand before:border-4 before:rounded-full before:border-n-strong checked:before:w-[18px] checked:before:h-[18px] checked:border checked:border-n-brand"
          @change="$emit('select', value)"
        />
      </div>
      <span class="text-n-slate-11 line-clamp-3 text-body-para text-start">
        {{ description }}
      </span>
    </div>

    <div
      class="w-full mt-auto rounded-md overflow-hidden border border-solid border-n-weak bg-n-slate-2 dark:bg-n-slate-1"
    >
      <slot />
    </div>
  </button>
</template>
