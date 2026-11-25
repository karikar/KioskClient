/* Debian kiosk - világos/sötét téma váltó. */
(function () {
  'use strict';

  var KEY = 'kiosk-theme';

  function stored() {
    try {
      var value = window.localStorage.getItem(KEY);
      return value === 'dark' ? 'dark' : 'light';
    } catch (e) {
      return 'light';
    }
  }

  function apply(theme) {
    var root = document.documentElement;
    if (theme === 'dark') {
      root.setAttribute('data-theme', 'dark');
    } else {
      root.removeAttribute('data-theme');
    }
    var button = document.getElementById('theme-toggle');
    if (button) {
      var dark = theme === 'dark';
      button.textContent = dark ? '☀' : '🌙';
      button.title = dark ? 'Világos téma' : 'Sötét téma';
      button.setAttribute('aria-label', button.title);
      button.setAttribute('aria-pressed', dark ? 'true' : 'false');
    }
  }

  function save(theme) {
    try {
      window.localStorage.setItem(KEY, theme);
    } catch (e) {
      /* privát mód: csak az aktuális oldalon érvényes */
    }
  }

  function apiBase() {
    if (window.location.protocol === 'http:' || window.location.protocol === 'https:') {
      return '';
    }
    var body = document.body;
    var admin = body ? body.getAttribute('data-admin') : '';
    if (admin) return admin.replace(/\/+$/, '');
    return 'http://127.0.0.1:8878';
  }

  function remoteLoad() {
    fetch(apiBase() + '/theme', { cache: 'no-store' })
      .then(function (response) {
        if (!response.ok) return null;
        return response.json();
      })
      .then(function (data) {
        if (data && (data.theme === 'dark' || data.theme === 'light')) {
          apply(data.theme);
          save(data.theme);
        }
      })
      .catch(function () { /* az admin szolgáltatás nem elérhető */ });
  }

  function remoteSave(theme) {
    fetch(apiBase() + '/theme', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ theme: theme })
    }).catch(function () { /* localStorage marad */ });
  }

  function initButton() {
    var button = document.getElementById('theme-toggle');
    remoteLoad();
    if (!button) return;
    var current = stored();
    apply(current);
    button.addEventListener('click', function () {
      current = current === 'dark' ? 'light' : 'dark';
      apply(current);
      save(current);
      remoteSave(current);
    });
  }

  apply(stored());

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initButton);
  } else {
    initButton();
  }

  window.addEventListener('storage', function (event) {
    if (event.key === KEY) apply(stored());
  });

  window.kioskTheme = {
    get: stored,
    set: function (theme) {
      var value = theme === 'dark' ? 'dark' : 'light';
      apply(value);
      save(value);
      remoteSave(value);
    }
  };
})();
