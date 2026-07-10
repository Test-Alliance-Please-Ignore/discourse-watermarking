import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class WatermarkSecretRotation extends Component {
  @service dialog;

  @tracked loading = false;

  @action
  rotate() {
    this.dialog.yesNoConfirm({
      message: i18n("discourse_watermarking.rotation.confirm"),
      didConfirm: async () => {
        this.loading = true;
        try {
          const response = await ajax(
            "/admin/plugins/discourse-watermarking/rotate-secret",
            { type: "POST" }
          );
          this.dialog.alert(
            i18n("discourse_watermarking.rotation.done", {
              fingerprint: response.secret_fingerprint,
            })
          );
          this.args.onRotated?.();
        } catch (error) {
          popupAjaxError(error);
        } finally {
          this.loading = false;
        }
      },
    });
  }

  <template>
    <div class="watermark-secret-rotation">
      <p>{{i18n "discourse_watermarking.rotation.description"}}</p>
      <DButton
        @action={{this.rotate}}
        @label="discourse_watermarking.rotation.button"
        @icon="arrows-rotate"
        @isLoading={{this.loading}}
        class="btn-danger watermark-secret-rotation__button"
      />
    </div>
  </template>
}
