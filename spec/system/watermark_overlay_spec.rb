# frozen_string_literal: true

RSpec.describe "Watermark overlay rendering" do
  fab!(:user)
  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  let(:overlay_selector) { ".d-view-layer" }

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_visual_opacity = 8
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  it "renders the overlay for an eligible user on a topic (desktop)" do
    sign_in(user)
    visit(topic.url)

    expect(page).to have_css(overlay_selector, visible: :all)

    mask = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("#{overlay_selector}"))
        .getPropertyValue("mask-image")
    JS
    expect(mask).to include("data:image/svg+xml")

    color = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector("#{overlay_selector}")).backgroundColor
    JS
    expect(color).to eq("rgb(0, 0, 2)")
  end

  it "renders the overlay on mobile", mobile: true do
    sign_in(user)
    visit(topic.url)

    expect(page).to have_css(overlay_selector, visible: :all)
  end

  it "does not render the overlay for anonymous visitors" do
    visit(topic.url)

    expect(page).to have_css("#main-outlet")
    expect(page).to have_no_css(overlay_selector, visible: :all)
  end

  it "does not render the overlay when the plugin is disabled" do
    SiteSetting.user_fingerprint_enabled = false
    sign_in(user)
    visit(topic.url)

    expect(page).to have_css("#main-outlet")
    expect(page).to have_no_css(overlay_selector, visible: :all)
  end

  it "does not render the overlay on admin pages" do
    sign_in(admin)
    visit("/admin")

    expect(page).to have_no_css(overlay_selector, visible: :all)
  end

  it "scopes the overlay to enabled categories" do
    other_topic = Fabricate(:topic)
    Fabricate(:post, topic: other_topic)
    SiteSetting.user_fingerprint_enabled_categories = category.id.to_s

    sign_in(user)

    visit(topic.url)
    expect(page).to have_css(overlay_selector, visible: :all)

    visit(other_topic.url)
    expect(page).to have_no_css(overlay_selector, visible: :all)
  end
end
