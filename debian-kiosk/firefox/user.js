// =============================================================================
// Debian kiosk - Firefox ESR profil beállítások (user.js)
//
// Ezt a fájlt a kiosk session minden indításkor a profilba másolja, ezért
// a profilban tett módosítások nem maradnak meg (szándékos, kiosk).
// A házirend (policies.json) ettől függetlenül is érvényesül.
// =============================================================================

// --- magyar nyelv ----------------------------------------------------------
user_pref("intl.locale.requested", "hu");
user_pref("intl.accept_languages", "hu-HU, hu, en-US, en");

// --- felület: csak vissza / előre / home + könyvjelzők ----------------------
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.toolbars.bookmarks.visibility", "always");
user_pref("browser.toolbarbuttons.introduced.homeButton", false);
user_pref("browser.altClickSave", false);

// --- indulás: mindig a helyi kezdőlap --------------------------------------
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "file:///srv/kiosk/start.html");
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.newtab.preload", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.uitour.enabled", false);

// --- ablakok, tabok: ne legyen "új ablak" káosz ---------------------------
user_pref("browser.link.open_newwindow", 1);
user_pref("browser.link.open_newwindow.restriction", 0);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.warnOnCloseOtherTabs", false);
user_pref("browser.tabs.warnOnOpen", false);
user_pref("browser.warnOnQuit", false);
user_pref("browser.tabs.loadInBackground", false);
user_pref("browser.tabs.closeWindowWithLastTab", true);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("dom.disable_open_during_load", true);
user_pref("privacy.popups.disable_from_plugins", 3);

// --- PDF: a böngészőben nyíljon meg (pdf.js) -------------------------------
user_pref("pdfjs.disabled", false);
user_pref("browser.download.open_pdf_attachments_inline", true);
user_pref("browser.download.start_downloads_in_tmp_dir", false);

// --- letöltések ------------------------------------------------------------
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.dir", "/var/lib/kiosk/Downloads");
user_pref("browser.download.folderList", 2);
user_pref("browser.download.alwaysOpenPanel", false);
user_pref("browser.download.manager.showWhenStarting", false);
user_pref("browser.helperApps.neverAsk.saveToDisk", "application/pdf,application/octet-stream,image/jpeg,image/png,text/plain");

// --- videó: automatikus lejátszás engedélyezve (kiosk) --------------------
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.block-event.enabled", false);

// --- biztonság / adatvédelem ---------------------------------------------
user_pref("signon.rememberSignons", false);
user_pref("browser.formfill.enable", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("browser.region.update.enabled", false);
user_pref("browser.translation.detectLanguage", false);
user_pref("browser.translation.ui.show", false);
user_pref("reader.parse-on-load.enabled", false);
user_pref("geo.enabled", false);
user_pref("permissions.default.geo", 2);
user_pref("permissions.default.camera", 2);
user_pref("permissions.default.microphone", 2);
user_pref("permissions.default.desktop-notification", 2);

// --- menük, gombok, frissítés --------------------------------------------
user_pref("ui.key.menuAccessKeyFocuses", false);
user_pref("browser.fullscreen.autohide", true);
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.discovery.enabled", false);
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("extensions.update.enabled", false);
user_pref("devtools.chrome.enabled", false);
user_pref("devtools.debugger.remote-enabled", false);

// A proxy beállítását a policies.json végzi (láthatatlanul, zárolva), hogy a
// ki-/bekapcsolás egy helyen történjen. Itt szándékosan nincs network.proxy.*.
