import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { userPath } from "discourse/lib/url";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class WatermarkDecoder extends Component {
  @tracked input = "";
  @tracked result = null;
  @tracked loading = false;

  get statusMessage() {
    if (!this.result) {
      return null;
    }
    return i18n(`discourse_watermarking.decoder.status.${this.result.status}`);
  }

  get matched() {
    return this.result?.status === "matched";
  }

  userUrl(user) {
    return userPath(user.username_lower || user.username);
  }

  @action
  updateInput(event) {
    this.input = event.target.value;
  }

  @action
  async decode() {
    this.loading = true;
    this.result = null;
    try {
      this.result = await ajax(
        "/admin/plugins/discourse-watermarking/decode",
        { type: "POST", data: { input: this.input } }
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  <template>
    <div class="watermark-decoder">
      <label for="watermark-decoder-input">
        {{i18n "discourse_watermarking.decoder.input_label"}}
      </label>
      <textarea
        id="watermark-decoder-input"
        class="watermark-decoder__input"
        rows="4"
        placeholder={{i18n "discourse_watermarking.decoder.input_placeholder"}}
        {{on "input" this.updateInput}}
      ></textarea>

      <DButton
        @action={{this.decode}}
        @label="discourse_watermarking.decoder.submit"
        @icon="fingerprint"
        @isLoading={{this.loading}}
        @disabled={{this.loading}}
        class="btn-primary watermark-decoder__submit"
      />

      {{#if this.result}}
        <div
          class="watermark-decoder__result watermark-decoder__result--{{this.result.status}}"
        >
          <h4>{{i18n "discourse_watermarking.decoder.result_title"}}</h4>
          <p>{{this.statusMessage}}</p>

          {{#if this.matched}}
            <dl>
              <dt>{{i18n "discourse_watermarking.decoder.matched_user"}}</dt>
              <dd>
                {{#each this.result.users as |user|}}
                  <a
                    href={{this.userUrl user}}
                    data-user-card={{user.username}}
                  >@{{user.username}}</a>
                {{/each}}
              </dd>
              <dt>{{i18n "discourse_watermarking.decoder.confidence"}}</dt>
              <dd>{{this.result.confidence}}</dd>
              <dt>{{i18n "discourse_watermarking.decoder.matched_count"}}</dt>
              <dd>{{this.result.matched_count}}</dd>
            </dl>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
