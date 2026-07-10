import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-watermarking";

export default {
  name: "discourse-watermarking-admin-nav",

  initialize(owner) {
    const currentUser = owner.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon(PLUGIN_ID, "fingerprint");
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          label: "discourse_watermarking.decoder.nav_label",
          route: "adminPlugins.show.discourse-watermarking-decoder",
        },
      ]);
    });
  },
};
