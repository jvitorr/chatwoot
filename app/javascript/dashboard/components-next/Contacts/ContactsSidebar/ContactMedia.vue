<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import {
  ATTACHMENT_TYPES,
  MEDIA_TYPES,
} from 'dashboard/components-next/message/constants';

import GalleryView from 'dashboard/components/widgets/conversation/components/GalleryView.vue';
import Media from 'dashboard/components-next/SharedAttachments/Media.vue';
import Files from 'dashboard/components-next/SharedAttachments/Files.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const MEDIA_PEEK_LIMIT = 12;
const FILES_PEEK_LIMIT = 6;

const route = useRoute();
const store = useStore();
const { t } = useI18n();

const attachmentsByContact = useMapGetter('contacts/getContactAttachments');
const uiFlags = useMapGetter('contacts/getUIFlags');

const attachments = computed(() =>
  attachmentsByContact.value(route.params.contactId)
);
const isFetching = computed(() => uiFlags.value.isFetchingAttachments);

const hasContent = computed(() =>
  attachments.value.some(
    a =>
      a.data_url &&
      (MEDIA_TYPES.includes(a.file_type) ||
        a.file_type === ATTACHMENT_TYPES.FILE)
  )
);

const mediaAttachments = computed(() =>
  attachments.value.filter(a => MEDIA_TYPES.includes(a.file_type) && a.data_url)
);

const showGallery = ref(false);
const selectedAttachment = ref(null);

const onMediaSelect = attachment => {
  selectedAttachment.value = attachment;
  showGallery.value = true;
};

const onFileSelect = attachment => {
  if (attachment.data_url) {
    window.open(attachment.data_url, '_blank', 'noopener,noreferrer');
  }
};

onMounted(() => {
  store.dispatch('contacts/fetchAttachments', route.params.contactId);
});
</script>

<template>
  <div class="p-6">
    <div v-if="isFetching" class="flex justify-center p-3">
      <Spinner class="size-5" />
    </div>
    <p v-else-if="!hasContent" class="p-3 text-sm text-center text-n-slate-11">
      {{ t('CONVERSATION_SIDEBAR.SHARED_FILES.EMPTY') }}
    </p>
    <div v-else class="flex flex-col gap-5">
      <Media
        :attachments="attachments"
        :peek-limit="MEDIA_PEEK_LIMIT"
        @select="onMediaSelect"
      />
      <Files
        :attachments="attachments"
        :peek-limit="FILES_PEEK_LIMIT"
        @select="onFileSelect"
      />
    </div>
    <GalleryView
      v-if="showGallery && selectedAttachment"
      v-model:show="showGallery"
      :attachment="selectedAttachment"
      :all-attachments="mediaAttachments"
      auto-play
      @close="showGallery = false"
    />
  </div>
</template>
