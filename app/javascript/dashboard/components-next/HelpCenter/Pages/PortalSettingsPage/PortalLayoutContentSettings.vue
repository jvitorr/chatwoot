<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import LayoutPreviewCard from './LayoutPreviewCard.vue';
import classicLayoutPreview from './classic-layout-preview.svg?raw';
import documentationLayoutPreview from './documentation-layout-preview.svg?raw';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  activePortal: { type: Object, required: true },
  isFetching: { type: Boolean, default: false },
});

const emit = defineEmits(['updatePortalConfiguration']);

const { t } = useI18n();

const portalConfig = computed(() => props.activePortal?.config || {});

const layout = ref(portalConfig.value.layout || 'classic');

watch(
  () => props.activePortal,
  () => {
    layout.value = portalConfig.value.layout || 'classic';
  },
  { deep: true }
);

const hasChanges = computed(
  () => layout.value !== (portalConfig.value.layout || 'classic')
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
          value="classic"
          :active="layout === 'classic'"
          :title="
            t('HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.CLASSIC.TITLE')
          "
          :description="
            t(
              'HELP_CENTER.PORTAL_SETTINGS.LAYOUT_CONTENT.LAYOUT.CLASSIC.DESCRIPTION'
            )
          "
          @select="value => (layout = value)"
        >
          <span v-dompurify-html="classicLayoutPreview" />
        </LayoutPreviewCard>

        <LayoutPreviewCard
          name="portal-layout"
          value="documentation"
          beta
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
          <span v-dompurify-html="documentationLayoutPreview" />
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
