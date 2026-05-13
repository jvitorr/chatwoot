<script>
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import TextArea from 'next/textarea/TextArea.vue';
import NextBanner from 'dashboard/components-next/banner/Banner.vue';

export default {
  components: {
    SettingsFieldSection,
    SettingsToggleSection,
    NextButton,
    TextArea,
    NextBanner,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      callingEnabled: this.inbox.provider_config?.calling_enabled || false,
      permissionRequestBody:
        this.inbox.provider_config?.call_permission_request_body || '',
      isUpdating: false,
      wabaCallingStatus: null,
      isFetchingWabaStatus: false,
      isEnablingCalling: false,
    };
  },
  computed: {
    phoneNumber() {
      return (
        this.inbox.provider_config?.phone_number || this.inbox.phone_number
      );
    },
    isWabaCallingDisabled() {
      return this.wabaCallingStatus && this.wabaCallingStatus !== 'ENABLED';
    },
    canEnableCalling() {
      return this.wabaCallingStatus === 'DISABLED';
    },
    wabaBannerColor() {
      return this.wabaCallingStatus === 'UNKNOWN' ? 'amber' : 'ruby';
    },
    wabaBannerTitle() {
      return this.wabaCallingStatus === 'UNKNOWN'
        ? this.$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.UNKNOWN_TITLE')
        : this.$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.DISABLED_TITLE');
    },
    wabaBannerDescription() {
      return this.wabaCallingStatus === 'UNKNOWN'
        ? this.$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.UNKNOWN_DESCRIPTION')
        : this.$t(
            'INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.DISABLED_DESCRIPTION'
          );
    },
  },
  watch: {
    'inbox.provider_config.calling_enabled'(val) {
      this.callingEnabled = val || false;
    },
    'inbox.provider_config.call_permission_request_body'(val) {
      this.permissionRequestBody = val || '';
    },
  },
  mounted() {
    this.fetchWabaCallingStatus();
  },
  methods: {
    async fetchWabaCallingStatus() {
      if (this.inbox.provider !== 'whatsapp_cloud') return;
      this.isFetchingWabaStatus = true;
      try {
        const { data } = await InboxesAPI.getWhatsappCallingStatus(
          this.inbox.id
        );
        this.wabaCallingStatus = data.status;
      } catch {
        this.wabaCallingStatus = 'UNKNOWN';
      } finally {
        this.isFetchingWabaStatus = false;
      }
    },
    async enableWhatsappCalling() {
      this.isEnablingCalling = true;
      try {
        const { data } = await InboxesAPI.enableWhatsappCalling(this.inbox.id);
        this.wabaCallingStatus = data.status;
        this.callingEnabled = true;
        await this.$store.dispatch('inboxes/get', this.inbox.id);
        useAlert(
          this.$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.ENABLE_SUCCESS')
        );
      } catch (error) {
        const message =
          error?.response?.data?.message ||
          this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE');
        useAlert(
          this.$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.ENABLE_FAILURE', {
            error: message,
          })
        );
      } finally {
        this.isEnablingCalling = false;
      }
    },
    async updateCallingSettings() {
      this.isUpdating = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: {
            provider_config: {
              ...this.inbox.provider_config,
              calling_enabled: this.callingEnabled,
              call_permission_request_body:
                this.permissionRequestBody.trim() || null,
            },
          },
        });
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col gap-6">
    <div
      v-if="isFetchingWabaStatus"
      class="flex items-center gap-2 text-body-main text-n-slate-11 px-3 py-2 rounded-xl bg-n-slate-3 border border-n-weak"
    >
      <span class="i-lucide-loader-circle animate-spin size-4" />
      {{ $t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.LOADING') }}
    </div>

    <div v-else-if="isWabaCallingDisabled" class="flex flex-col gap-3">
      <NextBanner :color="wabaBannerColor" class="!items-start">
        <div class="flex flex-col gap-0.5">
          <span class="font-medium">{{ wabaBannerTitle }}</span>
          <span class="text-xs">{{ wabaBannerDescription }}</span>
        </div>
      </NextBanner>
      <div v-if="canEnableCalling">
        <NextButton
          icon="i-lucide-phone-call"
          :is-loading="isEnablingCalling"
          :label="$t('INBOX_MGMT.WHATSAPP_CALLING.WABA_STATUS.ENABLE_ACTION')"
          @click="enableWhatsappCalling"
        />
      </div>
    </div>

    <template v-if="!isFetchingWabaStatus && !isWabaCallingDisabled">
      <SettingsToggleSection
        v-model="callingEnabled"
        :header="$t('INBOX_MGMT.WHATSAPP_CALLING.ENABLE.LABEL')"
        :description="$t('INBOX_MGMT.WHATSAPP_CALLING.ENABLE.DESCRIPTION')"
      />

      <SettingsFieldSection
        v-if="phoneNumber"
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.PHONE_NUMBER.LABEL')"
        :help-text="$t('INBOX_MGMT.WHATSAPP_CALLING.PHONE_NUMBER.HELP_TEXT')"
      >
        <woot-code :script="phoneNumber" lang="html" />
      </SettingsFieldSection>

      <SettingsFieldSection
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.LABEL')"
        :help-text="
          $t('INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.HELP_TEXT')
        "
      >
        <TextArea
          v-model="permissionRequestBody"
          :placeholder="
            $t(
              'INBOX_MGMT.WHATSAPP_CALLING.PERMISSION_REQUEST_BODY.PLACEHOLDER'
            )
          "
          auto-height
          resize
        />
      </SettingsFieldSection>

      <SettingsFieldSection
        :label="$t('INBOX_MGMT.WHATSAPP_CALLING.HOW_IT_WORKS.LABEL')"
        :help-text="$t('INBOX_MGMT.WHATSAPP_CALLING.HOW_IT_WORKS.DESCRIPTION')"
      />

      <div>
        <NextButton
          :is-loading="isUpdating"
          :label="$t('INBOX_MGMT.SETTINGS_POPUP.UPDATE')"
          @click="updateCallingSettings"
        />
      </div>
    </template>
  </div>
</template>
