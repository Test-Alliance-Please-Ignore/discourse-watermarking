import Component from "@glimmer/component";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import { i18n } from "discourse-i18n";

export default class WatermarkDiagnostics extends Component {
  get groupRestriction() {
    const count = this.args.status.enabled_group_count;
    return count > 0
      ? count
      : i18n("discourse_watermarking.diagnostics.unrestricted");
  }

  get categoryRestriction() {
    const count = this.args.status.enabled_category_count;
    return count > 0
      ? count
      : i18n("discourse_watermarking.diagnostics.unrestricted");
  }

  <template>
    <div class="watermark-diagnostics">
      <dl class="watermark-diagnostics__facts">
        <dt>{{i18n "discourse_watermarking.diagnostics.plugin_version"}}</dt>
        <dd>{{@status.plugin_version}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.enabled"}}</dt>
        <dd>{{@status.enabled}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.strategy"}}</dt>
        <dd>{{@status.strategy}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.visual_active"}}</dt>
        <dd>{{@status.visual_enabled}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.text_active"}}</dt>
        <dd>{{@status.text_enabled}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.opacity"}}</dt>
        <dd>{{@status.visual_opacity}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.density"}}</dt>
        <dd>{{@status.visual_density}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.secret_set"}}</dt>
        <dd>{{@status.secret_set}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.secret_fingerprint"}}</dt>
        <dd><code>{{@status.secret_fingerprint}}</code></dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.group_count"}}</dt>
        <dd>{{this.groupRestriction}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.category_count"}}</dt>
        <dd>{{this.categoryRestriction}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.homoglyph_category_count"}}</dt>
        <dd>{{@status.homoglyph_category_count}}</dd>

        <dt>{{i18n "discourse_watermarking.diagnostics.staff_only_decoder"}}</dt>
        <dd>{{@status.staff_only_decoder}}</dd>
      </dl>

      <h4>{{i18n "discourse_watermarking.diagnostics.recent_audits"}}</h4>
      {{#if @status.recent_audits.length}}
        <table class="watermark-diagnostics__audits">
          <thead>
            <tr>
              <th>{{i18n "discourse_watermarking.diagnostics.audit_when"}}</th>
              <th>{{i18n "discourse_watermarking.diagnostics.audit_by"}}</th>
              <th>{{i18n "discourse_watermarking.diagnostics.audit_status"}}</th>
              <th>{{i18n "discourse_watermarking.diagnostics.audit_matched"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @status.recent_audits as |audit|}}
              <tr>
                <td>{{dFormatDate audit.created_at}}</td>
                <td>{{audit.acting_username}}</td>
                <td>{{audit.status}}</td>
                <td>{{audit.matched_username}}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      {{else}}
        <p>{{i18n "discourse_watermarking.diagnostics.no_audits"}}</p>
      {{/if}}
    </div>
  </template>
}
