/* Renders fenced ```mermaid blocks (pymdownx.superfences custom_fences,
   see mkdocs.yml) and adds a click-to-expand pan/zoom modal on top of
   each rendered diagram, via svg-pan-zoom (loaded in extra_javascript).
   Re-runs on every Material "instant navigation" page swap, since mermaid
   doesn't know about those - see https://squidfunk.github.io/mkdocs-material/reference/diagrams/ */

(function () {
  function ensureModal() {
    if (document.getElementById("mfp-zoom-modal")) return;
    var modal = document.createElement("div");
    modal.id = "mfp-zoom-modal";
    modal.className = "mfp-zoom-modal";
    modal.innerHTML =
      '<div class="mfp-zoom-bar">' +
      '<span class="mfp-zoom-title" id="mfp-zoom-title"></span>' +
      '<span class="mfp-zoom-hint">scroll to zoom &middot; drag to pan &middot; double-click to reset &middot; Esc to close</span>' +
      '<button type="button" class="mfp-zoom-close" id="mfp-zoom-close" aria-label="Close">&times;</button>' +
      "</div>" +
      '<div class="mfp-zoom-holder" id="mfp-zoom-holder"></div>';
    document.body.appendChild(modal);

    document.getElementById("mfp-zoom-close").addEventListener("click", closeModal);
    modal.addEventListener("click", function (e) {
      if (e.target === modal) closeModal();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeModal();
    });
  }

  function openModal(svg, title) {
    ensureModal();
    var holder = document.getElementById("mfp-zoom-holder");
    holder.innerHTML = "";
    var clone = svg.cloneNode(true);
    clone.removeAttribute("height");
    clone.removeAttribute("width");
    clone.style.maxWidth = "none";
    clone.style.width = "100%";
    clone.style.height = "100%";
    holder.appendChild(clone);
    document.getElementById("mfp-zoom-title").textContent = title || "";
    document.getElementById("mfp-zoom-modal").classList.add("mfp-open");
    document.body.style.overflow = "hidden";

    if (window.__mfpPz) {
      try { window.__mfpPz.destroy(); } catch (e) {}
      window.__mfpPz = null;
    }
    if (window.svgPanZoom) {
      window.__mfpPz = window.svgPanZoom(clone, {
        controlIconsEnabled: true,
        zoomScaleSensitivity: 0.35,
        minZoom: 0.4,
        maxZoom: 30,
        fit: true,
        center: true,
        dblClickZoomEnabled: false
      });
      clone.addEventListener("dblclick", function () {
        if (window.__mfpPz) {
          window.__mfpPz.resetZoom();
          window.__mfpPz.center();
        }
      });
    }
  }

  function closeModal() {
    var modal = document.getElementById("mfp-zoom-modal");
    if (!modal) return;
    modal.classList.remove("mfp-open");
    document.body.style.overflow = "";
    if (window.__mfpPz) {
      try { window.__mfpPz.destroy(); } catch (e) {}
      window.__mfpPz = null;
    }
    var holder = document.getElementById("mfp-zoom-holder");
    if (holder) holder.innerHTML = "";
  }

  function wireDiagrams() {
    var nodes = document.querySelectorAll(".md-typeset .mermaid");
    for (var i = 0; i < nodes.length; i++) {
      (function (el) {
        if (el.dataset.mfpWired) return;
        var svg = el.querySelector("svg");
        if (!svg) return;
        el.dataset.mfpWired = "1";

        var panel = document.createElement("div");
        panel.className = "mermaid-panel";
        el.parentNode.insertBefore(panel, el);
        panel.appendChild(el);

        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "mfp-expand-btn";
        btn.setAttribute("aria-label", "Expand diagram");
        btn.innerHTML = "&#x2922;";
        panel.appendChild(btn);

        function go(e) {
          if (e) e.stopPropagation();
          var currentSvg = el.querySelector("svg");
          if (currentSvg) openModal(currentSvg, document.title);
        }
        btn.addEventListener("click", go);
        panel.addEventListener("click", go);
      })(nodes[i]);
    }
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(function () {
      if (typeof mermaid === "undefined") return;
      mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });
      var run = mermaid.run({ querySelector: ".mermaid" });
      if (run && typeof run.then === "function") {
        run.then(function () { setTimeout(wireDiagrams, 30); });
      } else {
        setTimeout(wireDiagrams, 150);
      }
    });
  }
})();
