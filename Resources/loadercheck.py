"""Check Paper and NeoForge declarations without loading add-on code."""
import io
import json
import re
import zipfile

from vendor import tomli, yaml


def descriptor(archive, name):
    entry = archive.getinfo(name)
    if entry.file_size > 2 * 1024 * 1024:
        raise ValueError(f"{name} is too large to inspect")
    return archive.read(entry).decode("utf-8-sig")


def numeric(version):
    if not isinstance(version, str) or not re.fullmatch(r"\d+(\.\d+)*", version):
        return None
    parts = list(map(int, version.split(".")))
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def in_range(version, expression):
    """Only judge Maven ranges whose ordering can be established numerically."""
    if expression in ("", "*"):
        return True
    value = numeric(version)
    if value is None:
        return None
    exact = re.fullmatch(r"\[([\d.]+)\]", expression)
    if exact and numeric(exact[1]) is not None:
        return value == numeric(exact[1])
    match = re.fullmatch(r"(\[|\()\s*([\d.]*)\s*,\s*([\d.]*)\s*(\]|\))", expression)
    if not match:
        return None
    left, low, high, right = match.groups()
    for bound in (low, high):
        if bound and numeric(bound) is None:
            return None
    return ((not low or value > numeric(low) or (left == "[" and value == numeric(low))) and
            (not high or value < numeric(high) or (right == "]" and value == numeric(high))))


def paper(archive, game, available, required, issues):
    modern = "paper-plugin.yml" in archive.namelist()
    filename = "paper-plugin.yml" if modern else "plugin.yml"
    if filename not in archive.namelist():
        raise ValueError("has no Paper plugin descriptor")
    # Keep version strings such as 1.20 and plugin names intact.
    meta = yaml.load(descriptor(archive, filename), Loader=yaml.BaseLoader)
    name = meta["name"]
    available.add(name)
    available.update(meta.get("provides") or [])
    api = numeric(meta.get("api-version"))
    if api is not None and numeric(game) is not None and api > numeric(game):
        issues.append(f"{name} needs server API {meta['api-version']} or later")
    if modern:
        for phase in ("bootstrap", "server"):
            for plugin, flags in ((meta.get("dependencies") or {}).get(phase) or {}).items():
                if str((flags or {}).get("required", "true")).lower() == "true":
                    required.append((name, plugin))
    else:
        required.extend((name, dep) for dep in meta.get("depend") or [])


def neo(archive, available, dependencies, budget, depth=0):
    names = set(archive.namelist())
    filename = next((f for f in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml") if f in names), None)
    jars = "META-INF/jarjar/metadata.json"
    manifest = descriptor(archive, "META-INF/MANIFEST.MF") if "META-INF/MANIFEST.MF" in names else ""
    if filename:
        meta = tomli.loads(descriptor(archive, filename))
        for mod in meta["mods"]:
            version = mod.get("version", "")
            if version == "${file.jarVersion}":
                match = re.search(r"(?im)^Implementation-Version: ([^\r\n]+)", manifest)
                version = match[1] if match else ""
            available[mod["modId"]] = version
        for owner, deps in meta.get("dependencies", {}).items():
            dependencies.extend((owner, dep) for dep in deps if dep.get("side", "BOTH") != "CLIENT")
    elif depth == 0 and jars not in names and not re.search(r"(?im)^FMLModType: (LIBRARY|GAMELIBRARY|LANGPROVIDER)\s*$", manifest):
        raise ValueError("has no NeoForge metadata")
    if jars in names:
        for nested in json.loads(descriptor(archive, jars))["jars"]:
            entry = archive.getinfo(nested["path"])
            budget[0] -= entry.file_size
            if depth >= 5 or budget[0] < 0:
                raise ValueError("bundled dependencies exceed inspection limits")
            with zipfile.ZipFile(io.BytesIO(archive.read(entry))) as inner:
                neo(inner, available, dependencies, budget, depth + 1)


def check_loader(profile, loader, options):
    is_paper = loader == "Paper"
    available = set() if is_paper else {"minecraft": profile.name, "neoforge": ""}
    if not is_paper:
        installer = re.fullmatch(r"neoforge-([\d.]+)-installer\.jar", options.get("NeoForgeJar", ""))
        if installer:
            available["neoforge"] = installer[1]
    dependencies, issues = [], []
    for jar in sorted((profile / ("plugins" if is_paper else "mods")).glob("*.jar")):
        try:
            with zipfile.ZipFile(jar) as archive:
                if is_paper:
                    paper(archive, profile.name, available, dependencies, issues)
                else:
                    neo(archive, available, dependencies, [128 * 1024 * 1024])
        except (KeyError, TypeError, AttributeError, ValueError, yaml.YAMLError, zipfile.BadZipFile) as error:
            issues.append(f"{jar.name}: {error}")
    for owner, dep in dependencies:
        if is_paper:
            if dep not in available:
                issues.append(f"{owner} needs plugin {dep}")
            continue
        name = dep["modId"]
        kind = dep.get("type", "required" if dep.get("mandatory", True) else "optional")
        if name not in available:
            if kind == "required":
                issues.append(f"{owner} needs {name}")
            continue
        expression = dep.get("versionRange", "*")
        matches = in_range(available[name], expression)
        if kind == "incompatible" and matches is True:
            issues.append(f"{owner} conflicts with {name} {expression}")
        elif kind in ("required", "optional") and matches is False:
            issues.append(f"{owner} needs {name} {expression} (found {available[name]})")
    return issues
