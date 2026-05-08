<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  activeSourceFilter: {
    type: String,
    default: 'all',
  },
  activeStatusFilter: {
    type: String,
    default: null,
  },
  activeSort: {
    type: String,
    default: 'recently_updated',
  },
  searchQuery: {
    type: String,
    default: '',
  },
});

const emit = defineEmits([
  'selectSource',
  'selectStatus',
  'selectSort',
  'search',
]);

const { t } = useI18n();

const openMenu = ref(null);

const sourceOptions = computed(() => [
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.SOURCE.ALL'),
    value: 'all',
    action: 'source',
    icon: 'i-lucide-files',
    isSelected: props.activeSourceFilter === 'all',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.SOURCE.WEB'),
    value: 'web',
    action: 'source',
    icon: 'i-lucide-link',
    isSelected: props.activeSourceFilter === 'web',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.SOURCE.PDF'),
    value: 'pdf',
    action: 'source',
    icon: 'i-lucide-file-text',
    isSelected: props.activeSourceFilter === 'pdf',
  },
]);

const statusOptions = computed(() => [
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.ANY'),
    value: null,
    action: 'status',
    icon: 'i-lucide-circle-dashed',
    isSelected: !props.activeStatusFilter,
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.UPDATED'),
    value: 'synced',
    action: 'status',
    icon: 'i-lucide-check-circle',
    isSelected: props.activeStatusFilter === 'synced',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.NEEDS_UPDATE'),
    value: 'stale',
    action: 'status',
    icon: 'i-lucide-clock',
    isSelected: props.activeStatusFilter === 'stale',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.UPDATING'),
    value: 'syncing',
    action: 'status',
    icon: 'i-lucide-refresh-cw',
    isSelected: props.activeStatusFilter === 'syncing',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.FAILED'),
    value: 'failed',
    action: 'status',
    icon: 'i-lucide-circle-x',
    isSelected: props.activeStatusFilter === 'failed',
  },
]);

const sortOptions = computed(() => [
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.SORT.RECENTLY_UPDATED'),
    value: 'recently_updated',
    action: 'sort',
    icon: 'i-lucide-arrow-down-up',
    isSelected: props.activeSort === 'recently_updated',
  },
  {
    label: t('CAPTAIN.DOCUMENTS.FILTERS.SORT.RECENTLY_CREATED'),
    value: 'recently_created',
    action: 'sort',
    icon: 'i-lucide-clock',
    isSelected: props.activeSort === 'recently_created',
  },
]);

const selectedSourceLabel = computed(
  () =>
    sourceOptions.value.find(item => item.value === props.activeSourceFilter)
      ?.label || t('CAPTAIN.DOCUMENTS.FILTERS.SOURCE.ALL')
);

const selectedStatusLabel = computed(
  () =>
    statusOptions.value.find(item => item.value === props.activeStatusFilter)
      ?.label || t('CAPTAIN.DOCUMENTS.FILTERS.STATUS.ANY')
);

const selectedSortLabel = computed(
  () =>
    sortOptions.value.find(item => item.value === props.activeSort)?.label ||
    t('CAPTAIN.DOCUMENTS.FILTERS.SORT.RECENTLY_UPDATED')
);

const closeMenu = () => {
  openMenu.value = null;
};

const toggleMenu = menu => {
  openMenu.value = openMenu.value === menu ? null : menu;
};

const handleMenuAction = ({ action, value }) => {
  closeMenu();
  if (action === 'source') {
    emit('selectSource', value);
  } else if (action === 'status') {
    emit('selectStatus', value);
  } else if (action === 'sort') {
    emit('selectSort', value);
  }
};
</script>

<template>
  <div
    v-on-clickaway="closeMenu"
    class="flex flex-col gap-3 w-full lg:flex-row lg:items-center lg:justify-between"
  >
    <div class="flex flex-wrap items-center gap-2">
      <div class="relative">
        <Button
          :label="selectedSourceLabel"
          icon="i-lucide-files"
          trailing-icon
          slate
          outline
          size="md"
          class="min-w-[10rem] !justify-between bg-n-solid-1"
          @click="toggleMenu('source')"
        >
          <template #default>
            <span class="min-w-0 truncate">{{ selectedSourceLabel }}</span>
            <Icon icon="i-lucide-chevron-down" class="shrink-0 size-4" />
          </template>
        </Button>
        <DropdownMenu
          v-if="openMenu === 'source'"
          :menu-items="sourceOptions"
          class="top-full mt-2 ltr:left-0 rtl:right-0 min-w-48"
          @action="handleMenuAction"
        />
      </div>

      <div class="relative">
        <Button
          :label="selectedStatusLabel"
          icon="i-lucide-circle-dashed"
          slate
          outline
          size="md"
          class="min-w-[10rem] !justify-between bg-n-solid-1"
          @click="toggleMenu('status')"
        >
          <template #default>
            <span class="min-w-0 truncate">{{ selectedStatusLabel }}</span>
            <Icon icon="i-lucide-chevron-down" class="shrink-0 size-4" />
          </template>
        </Button>
        <DropdownMenu
          v-if="openMenu === 'status'"
          :menu-items="statusOptions"
          class="top-full mt-2 ltr:left-0 rtl:right-0 min-w-52"
          @action="handleMenuAction"
        />
      </div>

      <div class="relative">
        <Button
          :label="selectedSortLabel"
          icon="i-lucide-arrow-down-up"
          slate
          outline
          size="md"
          class="min-w-[12rem] !justify-between bg-n-solid-1"
          @click="toggleMenu('sort')"
        >
          <template #default>
            <span class="min-w-0 truncate">{{ selectedSortLabel }}</span>
            <Icon icon="i-lucide-chevron-down" class="shrink-0 size-4" />
          </template>
        </Button>
        <DropdownMenu
          v-if="openMenu === 'sort'"
          :menu-items="sortOptions"
          class="top-full mt-2 ltr:left-0 rtl:right-0 min-w-56"
          @action="handleMenuAction"
        />
      </div>
    </div>

    <label
      class="relative flex items-center w-full h-10 rounded-lg outline outline-1 outline-n-container bg-n-solid-1 lg:max-w-72"
    >
      <Icon
        icon="i-lucide-search"
        class="absolute size-4 text-n-slate-11 ltr:left-3 rtl:right-3"
      />
      <input
        :value="searchQuery"
        type="search"
        :placeholder="t('CAPTAIN.DOCUMENTS.FILTERS.SEARCH_PLACEHOLDER')"
        class="w-full h-full py-0 text-sm border-0 reset-base bg-transparent text-n-slate-12 placeholder:text-n-slate-10 focus:outline-none ltr:pl-9 ltr:pr-3 rtl:pr-9 rtl:pl-3"
        @input="emit('search', $event.target.value)"
      />
    </label>
  </div>
</template>
