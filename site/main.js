"use strict";

// Fills the page from release.json (written by scripts/build-site.sh with
// install.sh), so the page, the Terminal line and the download never
// disagree.

const $ = (id) => document.getElementById(id);

function onIPhoneOrIPad() {
  // An iPad asking for desktop sites reports itself as a Mac; it is then
  // shown the page as a Mac would be, which is harmless.
  return /iPhone|iPad|iPod/.test(navigator.userAgent);
}

function wireCopy() {
  $("copy-command").addEventListener("click", async () => {
    const text = $("install-command").textContent;
    try {
      await navigator.clipboard.writeText(text);
      $("copy-command").textContent = "Copied";
      setTimeout(() => { $("copy-command").textContent = "Copy"; }, 2000);
    } catch {
      window.prompt("Copy this into Terminal:", text);
    }
  });
}

function formatSize(bytes) {
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

async function fillFromRelease() {
  let release;
  try {
    const response = await fetch("release.json", { cache: "no-cache" });
    if (!response.ok) throw new Error(String(response.status));
    release = await response.json();
  } catch {
    $("meta").textContent = "Not published yet";
    $("copy-command").disabled = true;
    return;
  }

  const minimum = String(release.minOSVersion).replace(/\.0$/, "");
  $("meta").textContent = `Version ${release.version} · Free · iOS ${minimum} or later`;
  $("install-command").textContent = release.installCommand;
  $("fact-version").textContent = `${release.version} (${release.buildVersion})`;
  $("fact-date").textContent = new Date(release.date).toLocaleDateString(undefined, { dateStyle: "medium" });
  $("fact-size").textContent = formatSize(release.setup.size);
  $("fact-needs").textContent = `Mac with Apple silicon, iOS ${minimum}+`;
  $("fact-setup-sha").textContent = release.setup.sha256;
  $("fact-ipa-sha").textContent = release.harborIPASha256;
  $("download-setup").href = release.setup.url;
  $("source-code").href = release.repository;
}

if (onIPhoneOrIPad()) {
  $("page-address").textContent = location.host + location.pathname;
  $("on-iphone").hidden = false;
}
wireCopy();
fillFromRelease();
