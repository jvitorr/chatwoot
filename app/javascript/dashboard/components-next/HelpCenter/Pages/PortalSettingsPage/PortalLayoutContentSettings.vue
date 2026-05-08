<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import LayoutPreviewCard from './LayoutPreviewCard.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  activePortal: { type: Object, required: true },
  isFetching: { type: Boolean, default: false },
});

const emit = defineEmits(['updatePortalConfiguration']);

const { t } = useI18n();

const portalConfig = computed(() => props.activePortal?.config || {});

const layout = ref(portalConfig.value.layout || 'default');

watch(
  () => props.activePortal,
  () => {
    layout.value = portalConfig.value.layout || 'default';
  },
  { deep: true }
);

const hasChanges = computed(
  () => layout.value !== (portalConfig.value.layout || 'default')
);

const handleSave = () => {
  emit('updatePortalConfiguration', {
    id: props.activePortal.id,
    slug: props.activePortal.slug,
    config: {
      layout: layout.value,
    },
  });
};
</script>

<template>
  <div class="flex flex-col w-full gap-6">
    <div class="flex flex-col gap-2">
      <h6 class="text-base font-medium text-n-slate-12">
        {{ t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.HEADER') }}
      </h6>
      <span class="text-sm text-n-slate-11">
        {{ t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.DESCRIPTION') }}
      </span>
    </div>

    <section class="flex flex-col gap-3">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-n-slate-11">
        <LayoutPreviewCard
          name="portal-layout"
          value="default"
          :active="layout === 'default'"
          :title="
            t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.DEFAULT.TITLE')
          "
          :description="
            t(
              'HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.DEFAULT.DESCRIPTION'
            )
          "
          @select="value => (layout = value)"
        >
          <svg
            viewBox="0 0 200 120"
            class="w-full h-auto block"
            aria-hidden="true"
          >
            <!-- top bar -->
            <rect
              x="0"
              y="0"
              width="200"
              height="14"
              fill="currentColor"
              opacity="0.1"
            />
            <rect
              x="14"
              y="5"
              width="20"
              height="4"
              rx="1"
              fill="currentColor"
              opacity="0.3"
            />
            <!-- container: left-aligned title -->
            <rect
              x="14"
              y="22"
              width="64"
              height="5"
              rx="1"
              fill="currentColor"
              opacity="0.32"
            />
            <!-- container: left-aligned search bar -->
            <rect
              x="14"
              y="32"
              width="128"
              height="9"
              rx="2"
              fill="currentColor"
              opacity="0.18"
            />
            <!-- category cards 2×2 (left-aligned within container) -->
            <rect
              x="14"
              y="70"
              width="82"
              height="19"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="104"
              y="70"
              width="82"
              height="19"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="14"
              y="93"
              width="82"
              height="19"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="104"
              y="93"
              width="82"
              height="19"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
          </svg>
        </LayoutPreviewCard>

        <LayoutPreviewCard
          name="portal-layout"
          value="documentation"
          :active="layout === 'documentation'"
          :title="
            t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.SIDEBAR.TITLE')
          "
          :description="
            t(
              'HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.SIDEBAR.DESCRIPTION'
            )
          "
          @select="value => (layout = value)"
        >
          <svg
            viewBox="0 0 200 120"
            class="w-full h-auto block"
            aria-hidden="true"
          >
            <rect
              x="0"
              y="0"
              width="200"
              height="14"
              fill="currentColor"
              opacity="0.1"
            />
            <rect
              x="6"
              y="5"
              width="20"
              height="4"
              rx="1"
              fill="currentColor"
              opacity="0.3"
            />
            <rect
              x="0"
              y="14"
              width="50"
              height="106"
              fill="currentColor"
              opacity="0.07"
            />
            <rect
              x="6"
              y="22"
              width="38"
              height="4"
              rx="1"
              fill="currentColor"
              opacity="0.25"
            />
            <rect
              x="6"
              y="32"
              width="30"
              height="3"
              rx="1"
              fill="currentColor"
              opacity="0.18"
            />
            <rect
              x="6"
              y="40"
              width="35"
              height="3"
              rx="1"
              fill="currentColor"
              opacity="0.18"
            />
            <rect
              x="6"
              y="48"
              width="28"
              height="3"
              rx="1"
              fill="currentColor"
              opacity="0.18"
            />
            <rect
              x="6"
              y="56"
              width="32"
              height="3"
              rx="1"
              fill="currentColor"
              opacity="0.18"
            />
            <rect
              x="60"
              y="25"
              width="80"
              height="6"
              rx="1"
              fill="currentColor"
              opacity="0.35"
            />
            <rect
              x="60"
              y="38"
              width="120"
              height="8"
              rx="2"
              fill="currentColor"
              opacity="0.18"
            />
            <rect
              x="60"
              y="55"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="101"
              y="55"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="142"
              y="55"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="60"
              y="82"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="101"
              y="82"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
            <rect
              x="142"
              y="82"
              width="37"
              height="22"
              rx="2"
              fill="currentColor"
              opacity="0.12"
            />
          </svg>
        </LayoutPreviewCard>
      </div>
    </section>

    <div class="flex justify-end">
      <Button
        :label="t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.SAVE')"
        :disabled="!hasChanges || isFetching"
        @click="handleSave"
      />
    </div>
  </div>
</template>
