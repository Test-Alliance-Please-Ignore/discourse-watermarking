import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import WatermarkDecoder from "discourse/plugins/discourse-watermarking/admin/components/watermark-decoder";
import WatermarkDiagnostics from "discourse/plugins/discourse-watermarking/admin/components/watermark-diagnostics";
import WatermarkSecretRotation from "discourse/plugins/discourse-watermarking/admin/components/watermark-secret-rotation";

const DiscourseWatermarkingDecoderPage = <template>
  <div class="discourse-watermarking admin-detail">
    <DPageSubheader
      @titleLabel={{i18n "discourse_watermarking.decoder.title"}}
      @descriptionLabel={{i18n "discourse_watermarking.decoder.description"}}
    />

    <AdminConfigAreaCard
      @heading="discourse_watermarking.decoder.title"
      class="discourse-watermarking__decoder"
    >
      <:content>
        <WatermarkDecoder />
      </:content>
    </AdminConfigAreaCard>

    <AdminConfigAreaCard
      @heading="discourse_watermarking.rotation.title"
      class="discourse-watermarking__rotation"
    >
      <:content>
        <WatermarkSecretRotation />
      </:content>
    </AdminConfigAreaCard>

    <AdminConfigAreaCard
      @heading="discourse_watermarking.diagnostics.title"
      class="discourse-watermarking__diagnostics"
    >
      <:content>
        <WatermarkDiagnostics @status={{@model}} />
      </:content>
    </AdminConfigAreaCard>

    <AdminConfigAreaCard
      @heading="discourse_watermarking.docs.title"
      class="discourse-watermarking__docs"
    >
      <:content>
        <ul>
          <li>{{i18n "discourse_watermarking.docs.readme"}}</li>
          <li>{{i18n "discourse_watermarking.docs.extract_tool"}}</li>
        </ul>
      </:content>
    </AdminConfigAreaCard>
  </div>
</template>;

export default DiscourseWatermarkingDecoderPage;
