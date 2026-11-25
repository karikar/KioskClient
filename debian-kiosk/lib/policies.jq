# ---------------------------------------------------------------------------
# Debian kiosk - Firefox ESR házirend (policies.json) generátor
#
# Bemenő változók (jq --arg / --argjson):
#   $start_url   : file:// URL a helyi kezdőlapra
#   $downloads   : letöltések könyvtára
#   $folder      : könyvjelző mappa neve
#   $home_title  : kezdőlap könyvjelző felirata
#   $admin_ui    : helyi admin/unlock URL (pl. http://127.0.0.1:8878/)
#   $proxy_port  : allowlist proxy portja
#   $enforce     : 1 = proxy kötelező, 0 = nincs proxy
#   $al          : normalizált allowlist (slurpfile)
# ---------------------------------------------------------------------------

$al[0] as $a
| ([ { Title: $home_title, URL: $start_url, Placement: "toolbar" } ]
   + [ $a.sites[]
       | { Title: .title,
           URL: (if .allowed == false
                 then ($admin_ui + "unlock?target=" + (.url | @uri))
                 else .url end),
           Placement: "toolbar",
           Folder: $folder } ]) as $bookmarks

| {
    policies: (
      {
        # --- frissítés, telemetria, értesítések kikapcsolása ---
        DisableAppUpdate: true,
        DisableTelemetry: true,
        DisableFirefoxStudies: true,
        DisablePocket: true,
        DisableFirefoxAccounts: true,
        DisableFeedbackCommands: true,
        DisableFormHistory: true,
        DisablePrivateBrowsing: true,
        DisableDeveloperTools: true,
        DisableSafeMode: true,
        DisableMasterPasswordCreation: true,
        DontCheckDefaultBrowser: true,
        NoDefaultBookmarks: true,
        OverrideFirstRunPage: "",
        OverridePostUpdatePage: "",
        CaptivePortal: false,

        # --- kezdőlap és könyvjelzők ---
        Homepage: { URL: $start_url, StartPage: "homepage", Locked: true },
        DisplayBookmarksToolbar: true,
        Bookmarks: $bookmarks,

        # --- about: oldalak és jelszavak tiltása ---
        BlockAboutConfig: true,
        BlockAboutAddons: true,
        BlockAboutProfiles: true,
        BlockAboutSupport: true,
        OfferToSaveLogins: false,
        PasswordManagerEnabled: false,
        PrintingEnabled: false,

        # --- extrák, onboarding ---
        UserMessaging: {
          WhatsNew: false,
          ExtensionRecommendations: false,
          FeatureRecommendations: false,
          UrlbarInterventions: false,
          SkipOnboarding: true
        },
        ExtensionSettings: { "*": { installation_mode: "blocked" } },

        # --- kiosk viselkedés ---
        Preferences: {
          "toolkit.legacyUserProfileCustomizations.stylesheets": true,
          "widget.use-xdg-desktop-portal.file-picker": 0,
          "widget.use-xdg-desktop-portal.open-uri": 0,
          "browser.toolbars.bookmarks.visibility": "always",
          "browser.startup.page": 1,
          "browser.newtabpage.enabled": false,
          "browser.shell.checkDefaultBrowser": false,
          "browser.link.open_newwindow": 1,
          "browser.link.open_newwindow.restriction": 0,
          "browser.tabs.warnOnClose": false,
          "browser.tabs.warnOnOpen": false,
          "browser.warnOnQuit": false,
          "browser.tabs.closeWindowWithLastTab": true,
          "browser.tabs.loadInBackground": false,
          "browser.sessionstore.resume_from_crash": false,
          "browser.startup.homepage_override.mstone": "ignore",
          "browser.messaging-system.whatsNewPanel.enabled": false,
          "browser.discovery.enabled": false,
          "browser.download.useDownloadDir": true,
          "browser.download.dir": $downloads,
          "browser.download.folderList": 2,
          "browser.download.start_downloads_in_tmp_dir": false,
          "browser.download.open_pdf_attachments_inline": true,
          "browser.helperApps.neverAsk.saveToDisk": "application/pdf,application/octet-stream,image/jpeg,image/png,text/plain",
          "pdfjs.disabled": false,
          "dom.disable_open_during_load": true,
          "dom.event.contextmenu.enabled": false,
          "privacy.popups.disable_from_plugins": 3,
          "media.autoplay.default": 0,
          "media.autoplay.blocking_policy": 0,
          "signon.rememberSignons": false,
          "browser.formfill.enable": false,
          "datareporting.policy.dataSubmissionEnabled": false,
          "datareporting.healthreport.uploadEnabled": false,
          "network.captive-portal-service.enabled": false,
          "network.connectivity-service.enabled": false,
          "network.proxy.no_proxies_on": "localhost, 127.0.0.1, ::1",
          "intl.locale.requested": "hu",
          "intl.accept_languages": "hu-HU, hu, en-US, en",
          "ui.key.menuAccessKeyFocuses": false,
          "browser.fullscreen.autohide": true,
          "browser.search.suggest.enabled": false,
          "browser.urlbar.suggest.searches": false,
          "app.update.enabled": false,
          "app.update.auto": false,
          "extensions.update.enabled": false,
          "browser.toolbarbuttons.introduced.homeButton": false
        },

        # --- hálózati allowlist (opcionális, de alapból be) ---
        Proxy: (
          if $enforce == 1 then {
            Mode: "manual",
            HTTPProxy: ("127.0.0.1:" + ($proxy_port | tostring)),
            UseHTTPProxyForAllProtocols: true,
            Locked: true
          } else null end
        )
      }
      | with_entries(select(.value != null))
    )
  }
