import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowDiscourseWatermarkingDecoder extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/discourse-watermarking/status");
  }
}
