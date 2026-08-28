/* Renders ```mermaid fences (pymdownx.superfences custom_fences in
   mkdocs.yml deliberately outputs class="mfp-diagram", NOT "mermaid")
   and adds a click-to-expand pan/zoom modal (svg-pan-zoom) on top.

   Why not just use Material's built-in Mermaid support (class="mermaid")?
   Traced it in bundle.js: Material renders each diagram's SVG inside a
   *closed* shadow root (`r.attachShadow({mode:"closed"})`) before
   swapping it in for the original <pre>. That's permanently opaque to
   outside JS - there is no way to reach that SVG to clone it into a zoom
   modal, or to add any UI on top of it at all. So this file renders the
   diagrams itself, via a differently-classed fence Material's handler
   never touches, giving normal light-DOM access to the output. */

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

  function wireExpand(el) {
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
  }

  function renderAndWire() {
    if (typeof mermaid === "undefined") return;
    var nodes = document.querySelectorAll(".md-typeset .mfp-diagram");
    var toRender = [];
    for (var i = 0; i < nodes.length; i++) {
      // Claim synchronously, before any rendering starts, so a second
      // document$ emission arriving before this one finishes can't grab
      // the same nodes and render them twice concurrently.
      if (!nodes[i].dataset.mfpClaimed) {
        nodes[i].dataset.mfpClaimed = "1";
        toRender.push(nodes[i]);
      }
    }
    if (toRender.length === 0) return;

    mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });

    // Deliberately mermaid.render(id, text) - the low-level, string-in/
    // string-out API - rather than mermaid.run({nodes: ...}). run()'s own
    // DOM-node handling was, empirically, unreliable here (it would
    // sometimes read back page chrome instead of the diagram source,
    // "No diagram type detected... for text: <nav class='md...").
    // Capturing the source text ourselves and inserting the returned SVG
    // ourselves sidesteps whatever that internal traversal was doing.
    toRender.forEach(function (el, i) {
      var source = el.textContent;
      var id = "mfp-mermaid-" + Date.now() + "-" + i;
      mermaid.render(id, source).then(
        function (result) {
          el.innerHTML = result.svg;
          if (typeof result.bindFunctions === "function") result.bindFunctions(el);
          wireExpand(el);
        },
        function (err) {
          console.error("mermaid-zoom: mermaid.render() failed for a diagram", err);
        }
      );
    });
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(function () {
      setTimeout(renderAndWire, 0);
    });
  } else {
    document.addEventListener("DOMContentLoaded", renderAndWire);
  }
})();
