/* Paperclip Profile leaves email read-only and has no password field.
   This overlay (installed by paperclip/setup.sh) adds both. */
(function () {
  "use strict";

  var PANEL_ID = "pc-profile-credentials";
  var PROFILE_PATH = "/company/settings/instance/profile";

  function isProfilePage() {
    return window.location.pathname.indexOf(PROFILE_PATH) !== -1;
  }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (key) {
      if (key === "text") node.textContent = attrs[key];
      else if (key === "html") node.innerHTML = attrs[key];
      else if (key === "on") Object.keys(attrs.on).forEach(function (ev) {
        node.addEventListener(ev, attrs.on[ev]);
      });
      else if (attrs[key] === true) node.setAttribute(key, "");
      else if (attrs[key] != null) node.setAttribute(key, String(attrs[key]));
    });
    (children || []).forEach(function (child) {
      if (child) node.appendChild(child);
    });
    return node;
  }

  function field(id, label, type, autocomplete) {
    return el("label", { class: "pc-cred-field", for: id }, [
      el("span", { text: label }),
      el("input", {
        id: id,
        type: type,
        autocomplete: autocomplete,
        spellcheck: "false",
      }),
    ]);
  }

  function ensureStyle() {
    if (document.getElementById("pc-cred-style")) return;
    var css = [
      "#" + PANEL_ID + "{position:fixed;z-index:40;box-sizing:border-box;",
      "padding:1rem 1.1rem 1.1rem;border-radius:12px;",
      "background:var(--card,#18181b);color:var(--card-foreground,#fafafa);",
      "border:1px solid var(--border,#27272a);",
      "box-shadow:0 10px 30px rgba(0,0,0,.28);font:13px/1.4 system-ui,sans-serif}",
      "#" + PANEL_ID + " h2{margin:0 0 .25rem;font-size:14px;font-weight:600}",
      "#" + PANEL_ID + " .pc-cred-help{margin:0 0 .75rem;color:var(--muted-foreground,#a1a1aa);font-size:12px}",
      "#" + PANEL_ID + " .pc-cred-field{display:flex;flex-direction:column;gap:.3rem;margin:0 0 .65rem}",
      "#" + PANEL_ID + " .pc-cred-field span{font-size:12px;font-weight:500}",
      "#" + PANEL_ID + " input{height:2.25rem;padding:0 .7rem;border-radius:8px;",
      "border:1px solid var(--input,#27272a);background:var(--background,#09090b);",
      "color:inherit;font:inherit}",
      "#" + PANEL_ID + " input:focus{outline:2px solid var(--ring,#3f3f46);outline-offset:1px}",
      "#" + PANEL_ID + " .pc-cred-actions{display:flex;justify-content:flex-end;gap:.5rem;margin-top:.25rem}",
      "#" + PANEL_ID + " button{height:2.15rem;padding:0 .9rem;border-radius:8px;border:0;",
      "background:var(--primary,#fafafa);color:var(--primary-foreground,#18181b);",
      "font:12px/1 system-ui,sans-serif;font-weight:600;cursor:pointer}",
      "#" + PANEL_ID + " button[disabled]{opacity:.6;cursor:default}",
      "#" + PANEL_ID + " .pc-cred-msg{min-height:1.1em;margin:.15rem 0 .5rem;font-size:12px}",
      "#" + PANEL_ID + " .pc-cred-msg.err{color:#f87171}",
      "#" + PANEL_ID + " .pc-cred-msg.ok{color:#4ade80}",
      "body.pc-cred-on #profile-email,body.pc-cred-on label[for='profile-email']+p,",
      "body.pc-cred-on #profile-email+p{visibility:hidden}",
    ].join("");
    document.head.appendChild(el("style", { id: "pc-cred-style", text: css }));
  }

  function panel() {
    var existing = document.getElementById(PANEL_ID);
    if (existing) return existing;
    var root = el("aside", { id: PANEL_ID, hidden: true, "aria-label": "Sign-in email and password" }, [
      el("h2", { text: "Email & password" }),
      el("p", { class: "pc-cred-help", text: "Paperclip's Profile page leaves these read-only. Saved values are what you use to sign in next time." }),
      el("p", { id: "pc-cred-msg", class: "pc-cred-msg", role: "status" }),
      field("pc-cred-email", "Email", "email", "username"),
      field("pc-cred-current", "Current password", "password", "current-password"),
      field("pc-cred-new", "New password", "password", "new-password"),
      field("pc-cred-confirm", "Confirm new password", "password", "new-password"),
      el("div", { class: "pc-cred-actions" }, [
        el("button", { id: "pc-cred-save", type: "button", text: "Save login" }),
      ]),
    ]);
    document.body.appendChild(root);
    document.getElementById("pc-cred-save").addEventListener("click", save);
    return root;
  }

  function setMsg(text, kind) {
    var msg = document.getElementById("pc-cred-msg");
    if (!msg) return;
    msg.textContent = text || "";
    msg.className = "pc-cred-msg" + (kind ? " " + kind : "");
  }

  function api(path, body) {
    return fetch(path, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
    }).then(function (res) {
      return res.text().then(function (text) {
        var data = null;
        if (text) {
          try { data = JSON.parse(text); } catch (err) { data = { message: text }; }
        }
        if (!res.ok) {
          var errMsg = (data && (data.message || data.error)) || ("Request failed (" + res.status + ")");
          if (typeof errMsg !== "string") errMsg = JSON.stringify(errMsg);
          throw new Error(errMsg);
        }
        return data;
      });
    });
  }

  function loadEmail() {
    var input = document.getElementById("pc-cred-email");
    if (!input || input.dataset.loaded === "1") return;
    var native = document.getElementById("profile-email");
    if (native && native.value) {
      input.value = native.value;
      input.dataset.loaded = "1";
      return;
    }
    fetch("/api/auth/get-session", { credentials: "include", headers: { Accept: "application/json" } })
      .then(function (res) { return res.json().catch(function () { return null; }); })
      .then(function (data) {
        var email = data && data.user && data.user.email;
        if (email && !input.value) input.value = email;
        input.dataset.loaded = "1";
      })
      .catch(function () {});
  }

  function place() {
    var root = panel();
    if (!isProfilePage()) {
      root.hidden = true;
      document.body.classList.remove("pc-cred-on");
      return;
    }
    ensureStyle();
    var native = document.getElementById("profile-email");
    var host = native && (native.closest(".space-y-2") || native.parentElement);
    if (!host) {
      root.hidden = true;
      document.body.classList.remove("pc-cred-on");
      return;
    }
    loadEmail();
    var box = host.getBoundingClientRect();
    var width = Math.max(box.width, 260);
    root.hidden = false;
    document.body.classList.add("pc-cred-on");
    root.style.left = Math.max(12, box.left) + "px";
    root.style.top = Math.max(12, box.top) + "px";
    root.style.width = Math.min(width, window.innerWidth - 24) + "px";
  }

  function save() {
    var email = (document.getElementById("pc-cred-email").value || "").trim();
    var current = document.getElementById("pc-cred-current").value || "";
    var next = document.getElementById("pc-cred-new").value || "";
    var confirm = document.getElementById("pc-cred-confirm").value || "";
    var native = document.getElementById("profile-email");
    var currentEmail = ((native && native.value) || "").trim();
    var btn = document.getElementById("pc-cred-save");
    var jobs = [];

    if (!email) {
      setMsg("Email is required.", "err");
      return;
    }
    if (next || confirm) {
      if (next.length < 8) {
        setMsg("New password must be at least 8 characters.", "err");
        return;
      }
      if (next !== confirm) {
        setMsg("New password and confirmation do not match.", "err");
        return;
      }
      if (!current) {
        setMsg("Current password is required to set a new one.", "err");
        return;
      }
    } else if (email === currentEmail) {
      setMsg("Nothing to save.", "err");
      return;
    }

    if (email && email !== currentEmail) {
      jobs.push(api("/api/auth/change-email", { newEmail: email }));
    }
    if (next) {
      jobs.push(api("/api/auth/change-password", {
        currentPassword: current,
        newPassword: next,
        revokeOtherSessions: false,
      }));
    }

    btn.disabled = true;
    setMsg("Saving…");
    Promise.all(jobs)
      .then(function () {
        setMsg("Saved. Use this email and password the next time you sign in.", "ok");
        document.getElementById("pc-cred-current").value = "";
        document.getElementById("pc-cred-new").value = "";
        document.getElementById("pc-cred-confirm").value = "";
        if (native) native.value = email;
      })
      .catch(function (err) {
        setMsg(err && err.message ? err.message : "Could not save.", "err");
      })
      .then(function () {
        btn.disabled = false;
      });
  }

  function hookHistory() {
    ["pushState", "replaceState"].forEach(function (name) {
      var orig = history[name];
      history[name] = function () {
        var ret = orig.apply(this, arguments);
        window.dispatchEvent(new Event("pc-cred-nav"));
        return ret;
      };
    });
    window.addEventListener("popstate", function () {
      window.dispatchEvent(new Event("pc-cred-nav"));
    });
  }

  ensureStyle();
  panel();
  hookHistory();
  window.addEventListener("pc-cred-nav", place);
  window.addEventListener("resize", place);
  window.addEventListener("scroll", place, true);
  new MutationObserver(place).observe(document.documentElement, { childList: true, subtree: true });
  place();
})();
