// rSshTerm product page: theme toggle, keyboard tabs, copy buttons, play videos only while visible.
(() => {
  const root = document.documentElement;
  const stored = (() => { try { return localStorage.getItem("theme"); } catch { return null; } })();
  if (stored === "light" || stored === "dark") root.dataset.theme = stored;

  const toggle = document.querySelector(".theme");
  const current = () => root.dataset.theme || "dark";  // dark unless the visitor picked light
  const label = () => { if (toggle) toggle.textContent = current() === "dark" ? "☀" : "☾"; };
  label();
  toggle?.addEventListener("click", () => {
    root.dataset.theme = current() === "dark" ? "light" : "dark";
    try { localStorage.setItem("theme", root.dataset.theme); } catch { /* private mode */ }
    label();
  });

  // Keyboard shortcut tabs (WAI-ARIA tabs pattern, arrow keys move between them).
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (e) => {
      const step = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!step) return;
      const next = tabs[(i + step + tabs.length) % tabs.length];
      select(next); next.focus();
    });
  });
  // Mac visitors see the macOS keys first.
  if (/Mac/.test(navigator.platform || navigator.userAgent)) {
    const mac = tabs.find((t) => t.id === "tab-mac");
    if (mac) select(mac);
  }

  // Copy buttons next to the install one-liners.
  document.querySelectorAll(".snippet").forEach((box) => {
    const btn = document.createElement("button");
    btn.className = "copy"; btn.type = "button"; btn.textContent = "Copy";
    btn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(box.querySelector("pre").innerText.trim());
        btn.textContent = "Copied";
      } catch { btn.textContent = "Select + copy"; }
      setTimeout(() => { btn.textContent = "Copy"; }, 1600);
    });
    box.append(btn);
  });

  // Demo videos play only on screen, and not at all when the visitor prefers reduced motion.
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const videos = document.querySelectorAll("video[data-autoplay]");
  if (still) { videos.forEach((v) => { v.controls = true; }); return; }
  const io = new IntersectionObserver((entries) => {
    entries.forEach(({ target, isIntersecting }) => {
      if (isIntersecting) target.play().catch(() => { target.controls = true; });
      else target.pause();
    });
  }, { threshold: 0.25 });
  videos.forEach((v) => io.observe(v));
})();
