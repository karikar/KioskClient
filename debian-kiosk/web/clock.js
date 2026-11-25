/* ==========================================================================
   Debian kiosk - dátum, hét napja, idő és aznapi névnap a fejlécben.

   A névnapadatok forrása: sbolch/name-days (MIT licenc), a magyar naptár
   szerint javított február 24-28. napokkal. Szökőévben a "Mátyás ugrása"
   szabály érvényes: február 24. szökőnap (nincs névnap), a 24-28. napok
   névnapjai pedig egy nappal későbbre tolódnak.
   ========================================================================== */
(function (root) {
    'use strict';

    var NAMEDAYS = {
        "01-01": ["Fruzsina"],
        "01-02": ["Ábel"],
        "01-03": ["Benjámin","Genovéva"],
        "01-04": ["Titusz"],
        "01-05": ["Simon"],
        "01-06": ["Boldizsár"],
        "01-07": ["Attila","Ramóna"],
        "01-08": ["Gyöngyvér"],
        "01-09": ["Marcell"],
        "01-10": ["Melánia"],
        "01-11": ["Ágota"],
        "01-12": ["Ernő"],
        "01-13": ["Veronika"],
        "01-14": ["Bódog"],
        "01-15": ["Lóránt"],
        "01-16": ["Gusztáv"],
        "01-17": ["Antal","Antónia"],
        "01-18": ["Piroska"],
        "01-19": ["Márió","Sára"],
        "01-20": ["Fábián","Sebestyén"],
        "01-21": ["Ágnes"],
        "01-22": ["Artúr","Vince"],
        "01-23": ["Rajmund","Zelma"],
        "01-24": ["Timót"],
        "01-25": ["Pál"],
        "01-26": ["Paula","Vanda"],
        "01-27": ["Angelika"],
        "01-28": ["Karola","Károly"],
        "01-29": ["Adél"],
        "01-30": ["Gerda","Martina"],
        "01-31": ["Marcella"],
        "02-01": ["Ignác"],
        "02-02": ["Aida","Karolina"],
        "02-03": ["Balázs"],
        "02-04": ["Csenge","Ráhel"],
        "02-05": ["Ágota","Ingrid"],
        "02-06": ["Dóra","Dorottya"],
        "02-07": ["Rómeó","Tódor"],
        "02-08": ["Aranka"],
        "02-09": ["Abigél","Alex"],
        "02-10": ["Elvira"],
        "02-11": ["Bertold","Marietta"],
        "02-12": ["Lídia","Lívia"],
        "02-13": ["Ella","Linda"],
        "02-14": ["Bálint","Valentin"],
        "02-15": ["Georgina","Kolos"],
        "02-16": ["Julianna","Lilla"],
        "02-17": ["Donát"],
        "02-18": ["Bernadett"],
        "02-19": ["Zsuzsanna"],
        "02-20": ["Aladár","Álmos"],
        "02-21": ["Eleonóra"],
        "02-22": ["Gerzson"],
        "02-23": ["Alfréd"],
        "02-24": ["Mátyás","Jázmin"],
        "02-25": ["Géza"],
        "02-26": ["Edina"],
        "02-27": ["Ákos","Bátor"],
        "02-28": ["Elemér"],
        "03-01": ["Albin"],
        "03-02": ["Lujza"],
        "03-03": ["Kornélia"],
        "03-04": ["Kázmér"],
        "03-05": ["Adorján","Adrián"],
        "03-06": ["Inez","Leonóra"],
        "03-07": ["Tamás"],
        "03-08": ["Zoltán"],
        "03-09": ["Fanni","Franciska"],
        "03-10": ["Ildikó"],
        "03-11": ["Szilárd"],
        "03-12": ["Gergely"],
        "03-13": ["Ajtony","Krisztián"],
        "03-14": ["Matild"],
        "03-15": ["Kristóf"],
        "03-16": ["Henrietta"],
        "03-17": ["Gertrúd","Patrik"],
        "03-18": ["Ede","Sándor"],
        "03-19": ["Bánk","József"],
        "03-20": ["Klaudia"],
        "03-21": ["Benedek"],
        "03-22": ["Beáta","Izolda"],
        "03-23": ["Emőke"],
        "03-24": ["Gábor","Karina"],
        "03-25": ["Irén","Írisz"],
        "03-26": ["Emánuel"],
        "03-27": ["Hajnalka"],
        "03-28": ["Gedeon","Johanna"],
        "03-29": ["Auguszta"],
        "03-30": ["Zalán"],
        "03-31": ["Árpád"],
        "04-01": ["Hugó"],
        "04-02": ["Áron"],
        "04-03": ["Buda","Richárd"],
        "04-04": ["Izidor"],
        "04-05": ["Vince"],
        "04-06": ["Bíborka","Vilmos"],
        "04-07": ["Herman"],
        "04-08": ["Dénes"],
        "04-09": ["Erhard"],
        "04-10": ["Zsolt"],
        "04-11": ["Leó","Szaniszló"],
        "04-12": ["Gyula"],
        "04-13": ["Ida"],
        "04-14": ["Tibor"],
        "04-15": ["Anasztázia","Tas"],
        "04-16": ["Csongor"],
        "04-17": ["Rudolf"],
        "04-18": ["Andrea","Ilma"],
        "04-19": ["Emma"],
        "04-20": ["Tivadar"],
        "04-21": ["Konrád"],
        "04-22": ["Csilla","Noémi"],
        "04-23": ["Béla"],
        "04-24": ["György"],
        "04-25": ["Márk"],
        "04-26": ["Ervin"],
        "04-27": ["Zita"],
        "04-28": ["Valéria"],
        "04-29": ["Péter"],
        "04-30": ["Katalin","Kitti"],
        "05-01": ["Fülöp","Jakab"],
        "05-02": ["Zsigmond"],
        "05-03": ["Irma","Tímea"],
        "05-04": ["Flórián","Mónika"],
        "05-05": ["Györgyi"],
        "05-06": ["Frida","Ivett"],
        "05-07": ["Gizella"],
        "05-08": ["Mihály"],
        "05-09": ["Gergely"],
        "05-10": ["Ármin","Pálma"],
        "05-11": ["Ferenc"],
        "05-12": ["Pongrác"],
        "05-13": ["Imola","Szervác"],
        "05-14": ["Bonifác"],
        "05-15": ["Szonja","Zsófia"],
        "05-16": ["Botond","Mózes"],
        "05-17": ["Paszkál"],
        "05-18": ["Alexandra","Erik"],
        "05-19": ["Ivó","Milán"],
        "05-20": ["Bernát","Felícia"],
        "05-21": ["Konstantin"],
        "05-22": ["Júlia","Rita"],
        "05-23": ["Dezső"],
        "05-24": ["Eliza","Eszter"],
        "05-25": ["Orbán"],
        "05-26": ["Evelin","Fülöp"],
        "05-27": ["Hella"],
        "05-28": ["Csanád","Emil"],
        "05-29": ["Magdolna"],
        "05-30": ["Janka","Zsanett"],
        "05-31": ["Angéla","Petronella"],
        "06-01": ["Tünde"],
        "06-02": ["Anita","Kármen"],
        "06-03": ["Klotild"],
        "06-04": ["Bulcsú"],
        "06-05": ["Fatime"],
        "06-06": ["Cintia","Norbert"],
        "06-07": ["Róbert"],
        "06-08": ["Medárd"],
        "06-09": ["Félix"],
        "06-10": ["Gréta","Margit"],
        "06-11": ["Barnabás"],
        "06-12": ["Villő"],
        "06-13": ["Anett","Antal"],
        "06-14": ["Vazul"],
        "06-15": ["Jolán","Vid"],
        "06-16": ["Jusztin"],
        "06-17": ["Alida","Laura"],
        "06-18": ["Arnold","Levente"],
        "06-19": ["Gyárfás"],
        "06-20": ["Rafael"],
        "06-21": ["Alajos"],
        "06-22": ["Paulina"],
        "06-23": ["Zoltán"],
        "06-24": ["Iván"],
        "06-25": ["Vilmos"],
        "06-26": ["János","Pál"],
        "06-27": ["László"],
        "06-28": ["Irén","Levente"],
        "06-29": ["Pál","Péter"],
        "06-30": ["Pál"],
        "07-01": ["Annamária","Tihamér"],
        "07-02": ["Ottó"],
        "07-03": ["Kornél","Soma"],
        "07-04": ["Ulrik"],
        "07-05": ["Emese","Sarolta"],
        "07-06": ["Csaba"],
        "07-07": ["Apollónia"],
        "07-08": ["Ellák"],
        "07-09": ["Lukrécia"],
        "07-10": ["Amália"],
        "07-11": ["Lili","Nóra"],
        "07-12": ["Dalma","Izabella"],
        "07-13": ["Jenő"],
        "07-14": ["Örs","Stella"],
        "07-15": ["Henrik","Roland"],
        "07-16": ["Valter"],
        "07-17": ["Elek","Endre"],
        "07-18": ["Frigyes"],
        "07-19": ["Emília"],
        "07-20": ["Illés"],
        "07-21": ["Dániel","Daniella"],
        "07-22": ["Magdolna"],
        "07-23": ["Lenke"],
        "07-24": ["Kincső","Kinga"],
        "07-25": ["Jakab","Kristóf"],
        "07-26": ["Anikó","Anna"],
        "07-27": ["Liliána","Olga"],
        "07-28": ["Szabolcs"],
        "07-29": ["Flóra","Márta"],
        "07-30": ["Judit","Xénia"],
        "07-31": ["Oszkár"],
        "08-01": ["Boglárka"],
        "08-02": ["Lehel"],
        "08-03": ["Hermina"],
        "08-04": ["Dominika","Domonkos"],
        "08-05": ["Krisztina"],
        "08-06": ["Berta","Bettina"],
        "08-07": ["Ibolya"],
        "08-08": ["László"],
        "08-09": ["Emőd"],
        "08-10": ["Lőrinc"],
        "08-11": ["Tiborc"],
        "08-12": ["Klára"],
        "08-13": ["Ipoly"],
        "08-14": ["Marcell"],
        "08-15": ["Mária"],
        "08-16": ["Ábrahám"],
        "08-17": ["Jácint"],
        "08-18": ["Ilona"],
        "08-19": ["Huba"],
        "08-20": ["István"],
        "08-21": ["Hajna","Sámuel"],
        "08-22": ["Menyhért","Mirjam"],
        "08-23": ["Bence"],
        "08-24": ["Bertalan"],
        "08-25": ["Lajos","Patrícia"],
        "08-26": ["Izsó"],
        "08-27": ["Gáspár"],
        "08-28": ["Ágoston"],
        "08-29": ["Beatrix","Erna"],
        "08-30": ["Rózsa"],
        "08-31": ["Bella","Erika"],
        "09-01": ["Egon","Egyed"],
        "09-02": ["Dorina","Rebeka"],
        "09-03": ["Hilda"],
        "09-04": ["Rozália"],
        "09-05": ["Lőrinc","Viktor"],
        "09-06": ["Zakariás"],
        "09-07": ["Regina"],
        "09-08": ["Adrienn","Mária"],
        "09-09": ["Ádám"],
        "09-10": ["Hunor","Nikolett"],
        "09-11": ["Teodóra"],
        "09-12": ["Mária"],
        "09-13": ["Kornél"],
        "09-14": ["Roxána","Szeréna"],
        "09-15": ["Enikő","Melitta"],
        "09-16": ["Edit"],
        "09-17": ["Zsófia"],
        "09-18": ["Diána"],
        "09-19": ["Vilhelmina"],
        "09-20": ["Friderika"],
        "09-21": ["Máté","Mirella"],
        "09-22": ["Móric"],
        "09-23": ["Tekla"],
        "09-24": ["Gellért","Mercédesz"],
        "09-25": ["Eufrozina","Kende"],
        "09-26": ["Jusztina"],
        "09-27": ["Adalbert"],
        "09-28": ["Vencel"],
        "09-29": ["Mihály"],
        "09-30": ["Jeromos"],
        "10-01": ["Malvin"],
        "10-02": ["Petra"],
        "10-03": ["Helga"],
        "10-04": ["Ferenc"],
        "10-05": ["Aurél"],
        "10-06": ["Brúnó","Renáta"],
        "10-07": ["Amália"],
        "10-08": ["Koppány"],
        "10-09": ["Dénes"],
        "10-10": ["Gedeon"],
        "10-11": ["Brigitta"],
        "10-12": ["Miksa"],
        "10-13": ["Ede","Kálmán"],
        "10-14": ["Helén"],
        "10-15": ["Teréz"],
        "10-16": ["Gál"],
        "10-17": ["Hedvig"],
        "10-18": ["Lukács"],
        "10-19": ["Nándor"],
        "10-20": ["Vendel"],
        "10-21": ["Klementina","Orsolya"],
        "10-22": ["Előd"],
        "10-23": ["Gyöngyi"],
        "10-24": ["Salamon"],
        "10-25": ["Bianka","Blanka"],
        "10-26": ["Dömötör"],
        "10-27": ["Szabina"],
        "10-28": ["Simon","Szimonetta"],
        "10-29": ["Nárcisz"],
        "10-30": ["Alfonz"],
        "10-31": ["Farkas"],
        "11-01": ["Marianna"],
        "11-02": ["Achilles"],
        "11-03": ["Győző"],
        "11-04": ["Károly"],
        "11-05": ["Imre"],
        "11-06": ["Lénárd"],
        "11-07": ["Rezső"],
        "11-08": ["Zsombor"],
        "11-09": ["Tivadar"],
        "11-10": ["Réka"],
        "11-11": ["Márton"],
        "11-12": ["Jónás","Renátó"],
        "11-13": ["Szilvia"],
        "11-14": ["Aliz","Klementina"],
        "11-15": ["Adalbert","Albert","Lipót"],
        "11-16": ["Ödön"],
        "11-17": ["Hortenzia"],
        "11-18": ["Jenő"],
        "11-19": ["Erzsébet"],
        "11-20": ["Jolán"],
        "11-21": ["Olivér"],
        "11-22": ["Cecília"],
        "11-23": ["Kelemen","Klementina"],
        "11-24": ["Emma"],
        "11-25": ["Katalin"],
        "11-26": ["Virág"],
        "11-27": ["Virgil"],
        "11-28": ["Stefánia"],
        "11-29": ["Taksony"],
        "11-30": ["Andor","András"],
        "12-01": ["Elza"],
        "12-02": ["Melinda","Vivien"],
        "12-03": ["Ferenc","Olívia"],
        "12-04": ["Barbara","Borbála"],
        "12-05": ["Vilma"],
        "12-06": ["Miklós"],
        "12-07": ["Ambrus"],
        "12-08": ["Mária"],
        "12-09": ["Natália"],
        "12-10": ["Judit"],
        "12-11": ["Árpád"],
        "12-12": ["Gabriella"],
        "12-13": ["Luca","Otília"],
        "12-14": ["Szilárda"],
        "12-15": ["Valér"],
        "12-16": ["Aletta","Etelka"],
        "12-17": ["Lázár","Olimpia"],
        "12-18": ["Auguszta"],
        "12-19": ["Viola"],
        "12-20": ["Teofil"],
        "12-21": ["Tamás"],
        "12-22": ["Zénó"],
        "12-23": ["Viktória"],
        "12-24": ["Ádám","Éva"],
        "12-25": ["Eugénia"],
        "12-26": ["István"],
        "12-27": ["János"],
        "12-28": ["Kamilla"],
        "12-29": ["Tamara","Tamás"],
        "12-30": ["Dávid"],
        "12-31": ["Szilveszter"]
    };

    var MONTHS = [
        'január', 'február', 'március', 'április', 'május', 'június',
        'július', 'augusztus', 'szeptember', 'október', 'november', 'december'
    ];

    var WEEKDAYS = [
        'vasárnap', 'hétfő', 'kedd', 'szerda', 'csütörtök', 'péntek', 'szombat'
    ];

    function pad2(n) {
        return (n < 10 ? '0' : '') + n;
    }

    function isLeap(year) {
        return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
    }

    function namesFor(date) {
        var month = date.getMonth() + 1;
        var day = date.getDate();

        if (month === 2 && isLeap(date.getFullYear())) {
            // "Mátyás ugrása": feb. 24. szökőnap, 25-29. a 24-28. névnapjai.
            if (day === 24) return [];
            if (day >= 25 && day <= 29) day -= 1;
        }

        var names = NAMEDAYS[pad2(month) + '-' + pad2(day)];
        return names ? names.slice() : [];
    }

    function format(date) {
        var text = date.getFullYear() + '. ' + MONTHS[date.getMonth()] + ' '
            + date.getDate() + '. (' + WEEKDAYS[date.getDay()] + ')'
            + ' · ' + pad2(date.getHours()) + ':' + pad2(date.getMinutes());

        var names = namesFor(date);
        if (names.length > 0) {
            text += ' · Névnap: ' + names.join(', ');
        }
        return text;
    }

    // Rejtett admin belépés: Ctrl+Alt+A. A body data-admin attribútuma
    // mondja meg, hova navigáljon (a PIN-kapu az admin oldalon jelenik meg).
    function initAdminShortcut() {
        var body = document.body;
        var target = body ? body.getAttribute('data-admin') : '';
        if (!target) return;

        document.addEventListener('keydown', function (event) {
            if (event.ctrlKey && event.altKey && !event.shiftKey &&
                (event.code === 'KeyA' || event.key === 'a' || event.key === 'A')) {
                event.preventDefault();
                root.location.href = target;
            }
        });
    }

    // Címbeviteli mező a fejlécben: ha nincs séma, https://-t feltételezünk.
    function initAddressBar() {
        var form = document.getElementById('address-form');
        var input = document.getElementById('address');
        if (!form || !input) return;

        form.addEventListener('submit', function (event) {
            event.preventDefault();
            var value = input.value.trim();
            if (!value) return;
            if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
                value = 'https://' + value;
            }
            var scheme = value.split(':', 1)[0].toLowerCase();
            if (scheme !== 'http' && scheme !== 'https') return;
            root.location.href = value;
        });
    }

    // PIN-es ideiglenes proxy-feloldás a kezdőlap fejlécében.
    function initUnlock() {
        var body = document.body;
        var target = body ? body.getAttribute('data-admin') : '';
        var btn = document.getElementById('unlock-btn');
        var lockBtn = document.getElementById('lock-btn');
        var modal = document.getElementById('unlock-modal');
        var frame = document.getElementById('unlock-frame');
        var close = document.getElementById('unlock-close');
        var direct = document.getElementById('unlock-direct');
        var toast = document.getElementById('unlock-toast');
        if (!target || !btn || !modal || !frame) return;

        var origin;
        try { origin = new URL(target).origin; } catch (e) { return; }
        var base = target.replace(/\/?$/, '/');
        var embedUrl = base + 'unlock?embed=1';
        var lockUrl = base + 'unlock?embed=1&lock=1';
        var pendingTarget = null;

        function closeModal() {
            modal.hidden = true;
            frame.src = 'about:blank';
            pendingTarget = null;
        }

        function openModal() {
            pendingTarget = null;
            if (direct) direct.href = base + 'unlock';
            frame.src = embedUrl;
            modal.hidden = false;
        }

        function openFor(url) {
            pendingTarget = String(url || '');
            var encoded = encodeURIComponent(pendingTarget);
            if (direct) direct.href = base + 'unlock?target=' + encoded;
            frame.src = embedUrl + '&target=' + encoded;
            modal.hidden = false;
        }

        function openLock() {
            pendingTarget = null;
            if (direct) direct.href = base + 'unlock?lock=1';
            frame.src = lockUrl;
            modal.hidden = false;
        }

        function showToast(text) {
            if (!toast) return;
            toast.textContent = text;
            toast.hidden = false;
            setTimeout(function () { toast.hidden = true; }, 8000);
        }

        btn.addEventListener('click', openModal);
        if (lockBtn) lockBtn.addEventListener('click', openLock);
        if (close) close.addEventListener('click', closeModal);
        modal.addEventListener('click', function (event) {
            if (event.target === modal) closeModal();
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && !modal.hidden) closeModal();
        });

        window.addEventListener('message', function (event) {
            if (event.origin !== origin || !event.data) return;
            if (event.data.type === 'kiosk-lock') {
                closeModal();
                if (event.data.ok) showToast('Böngészés visszazárva.');
                return;
            }
            if (event.data.type !== 'kiosk-unlock') return;
            var next = pendingTarget;
            closeModal();
            if (event.data.ok) {
                if (next) {
                    root.location.href = next;
                    return;
                }
                showToast('Szabad böngészés bekapcsolva' +
                    (event.data.minutes ? ' (' + event.data.minutes + ' perc)' : '') +
                    '. Utána a proxy automatikusan visszazár.');
            }
        });

        return { openFor: openFor };
    }

    // A főoldalon a tiltott (allowed: false) csempékre kattintva PIN-ablakot
    // ajánlunk fel; sikeres PIN után a proxy feloldva nyílik meg a cél.
    function initBlockedTiles(api) {
        var tiles = document.querySelectorAll('a.tile-blocked');
        Array.prototype.forEach.call(tiles, function (tile) {
            tile.addEventListener('click', function (event) {
                var url = tile.getAttribute('data-url') || tile.href;
                if (!url) return;
                event.preventDefault();
                if (api && api.openFor) api.openFor(url);
                else root.location.href = url;
            });
        });
    }

    function start() {
        initAdminShortcut();
        initAddressBar();
        var unlockApi = initUnlock();
        initBlockedTiles(unlockApi);

        var el = document.getElementById('clock');
        if (!el) return;

        function tick() {
            el.textContent = format(new Date());
        }

        tick();
        root.setInterval(tick, 20000);
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = {
            NAMEDAYS: NAMEDAYS,
            format: format,
            namesFor: namesFor,
            isLeap: isLeap
        };
    }

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start);
        } else {
            start();
        }
    }
}(typeof globalThis !== 'undefined' ? globalThis : this));
