"""VIctory copié dans third_party/victory (la branche anyxboxx/fork-7b0-lot9-murs de LooperSalty/victory plus 57 commits pour Proton et les cartes AMD, rejoués avec leurs auteurs) et réglages par défaut du lanceur."""
import configparser
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parents[1]
VICTORY = RACINE / "third_party" / "victory"
REGLAGES = (
    "VICTORY_SHADER_LOOP_LIMIT", "VICTORY_LATE_WAIT", "VICTORY_WIDE_BACK",
    "VICTORY_CARD_BUFFERS_MIN_MB", "VICTORY_CARD_BUFFERS_MB", "VICTORY_DSTORAGE_NOTIFY",
    "VICTORY_STAGING_POOL_MB",
)
# Absentes du code de VIctory au commit épinglé : les poser ne change rien.
ABSENTES = (
    "VICTORY_RT_MISS", "VICTORY_WAVE32_READFIRSTLANE", "VICTORY_WAVE32_CROSSLANE", "VICTORY_SKIP_BVH_BUILDER",
    "VICTORY_CAPPED_DYNAMIC",
)


def _lanceur():
    return (RACINE / "tools" / "lancer_victory.ps1").read_text(encoding="utf-8")


def _variables_posees(texte):
    """Noms VICTORY_* posés par le lanceur : table des réglages et affectations $env:."""
    table = texte[texte.index("$tuned = [ordered]@{"):texte.index("foreach ($name in $tuned.Keys)")]
    noms = set(re.findall(r"^\s*(VICTORY_[A-Z0-9_]+)\s*=", table, re.MULTILINE))
    return noms | set(re.findall(r"\$env:(VICTORY_[A-Z0-9_]+)\s*=", texte))


def test_gitmodules_no_longer_declares_victory():
    declares = configparser.ConfigParser()
    declares.read(RACINE / ".gitmodules", encoding="utf-8")
    assert all(declares[s]["path"] != "third_party/victory" for s in declares.sections())


def test_victory_source_is_tracked_in_the_repository():
    assert (VICTORY / "Cargo.toml").is_file() and (VICTORY / "LICENSE").is_file()
    sortie = subprocess.run(["git", "ls-files", "-s", "third_party/victory"], cwd=RACINE, capture_output=True,
                            text=True, check=False).stdout
    assert not any(ligne.startswith("160000 ") for ligne in sortie.splitlines())   # aucun gitlink


def test_launcher_sets_the_tuned_settings_and_can_turn_them_off():
    texte = _lanceur()
    for nom in REGLAGES:
        assert nom in texte, nom
    assert "$NoTunedSettings" in texte and "-not $NoTunedSettings" in texte


def test_launcher_does_not_set_the_relay():
    # Fork issue #89: the relay hides the characters' skin and overlaps the subtitles.
    assert "VICTORY_RELAY" not in _variables_posees(_lanceur())


def test_launcher_leaves_out_variables_victory_does_not_read():
    poses = _variables_posees(_lanceur())
    assert not poses & set(ABSENTES)


def test_launcher_turns_dred_on_only_when_asked():
    texte = _lanceur()
    assert "[switch]$Dred" in texte
    table = texte[texte.index("$tuned = [ordered]@{"):texte.index("foreach ($name in $tuned.Keys)")]
    assert "VICTORY_D3D12_DRED" not in table
    assert re.search(r"if \(\$Dred\) \{\s*\$env:VICTORY_D3D12_DRED = '1'", texte)


def test_every_variable_the_launcher_sets_is_read_by_victory():
    code = "\n".join(f.read_text(encoding="utf-8", errors="replace") for f in VICTORY.rglob("*.rs")
                     if "target" not in f.relative_to(VICTORY).parts)
    for nom in sorted(_variables_posees(_lanceur()) - {"VICTORY_GAME_DIR", "VICTORY_SKIP_PIPELINES"}):
        assert f'"{nom}"' in code, nom


def test_launcher_keeps_its_parameters_and_builds_with_the_diag_profile():
    texte = _lanceur()
    assert "$GameDir" in texte and "$SkipPipelines" in texte
    assert "--profile diag -p victory --features diagnostics" in texte


def test_launcher_uses_microsofts_xg_library_only_when_given():
    texte = _lanceur()
    assert "[string]$XgDll" in texte
    assert "[ValidateSet('real', 'compare')][string]$XgMode = 'real'" in texte
    table = texte[texte.index("$tuned = [ordered]@{"):texte.index("foreach ($name in $tuned.Keys)")]
    assert "VICTORY_XG" not in table
    bloc = texte[texte.index("if ($PSBoundParameters.ContainsKey('XgDll') -and $XgDll) {"):texte.index("& $exe run")]
    assert "Test-Path -LiteralPath $XgDll -PathType Leaf" in bloc and "throw" in bloc
    assert "$env:VICTORY_XG_DLL =" in bloc and "$env:VICTORY_XG_MODE = $XgMode" in bloc


# Faux outil console (.NET Framework, compilé par Windows PowerShell) : copié en cargo.exe et en victory.exe, il note
# « nom arguments » dans FAKE_TOOL_LOG, affiche le réglage de hachage de victory et rend le code de
# FAKE_TOOL_EXIT_<NOM> (0 par défaut).
FAUX_OUTIL = r"""
using System; using System.IO;
public static class FakeTool {
    public static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetEntryAssembly().Location);
        File.AppendAllText(Environment.GetEnvironmentVariable("FAKE_TOOL_LOG"),
                           name + " " + string.Join(" ", args) + Environment.NewLine);
        if (name == "victory") {
            Console.WriteLine("card rehash runs: " + (Environment.GetEnvironmentVariable("VICTORY_CARD_REHASH_RUNS") ?? "unset"));
        }
        string code = Environment.GetEnvironmentVariable("FAKE_TOOL_EXIT_" + name.ToUpperInvariant());
        return string.IsNullOrEmpty(code) ? 0 : int.Parse(code);
    }
}
"""
CODE_ECHEC_CARGO = 101
CODE_SORTIE_VICTORY = 7


@pytest.fixture(scope="module")
def faux_outil(tmp_path_factory):
    if sys.platform != "win32" or not shutil.which("powershell"):
        pytest.skip("le lanceur est un script Windows PowerShell")
    dossier = tmp_path_factory.mktemp("faux-outil")
    source, exe = dossier / "FakeTool.cs", dossier / "FakeTool.exe"
    source.write_text(FAUX_OUTIL, encoding="utf-8")
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    f"Add-Type -Path '{source}' -OutputAssembly '{exe}' -OutputType ConsoleApplication"],
                   check=True, capture_output=True, timeout=120)
    return exe


def _lancer(tmp_path, faux_outil, code_cargo=0, options=()):
    """Lance une copie du vrai lanceur : faux dépôt, faux jeu, faux cargo sur le PATH, victory.exe déjà compilé."""
    script = tmp_path / "depot" / "tools" / "lancer_victory.ps1"
    script.parent.mkdir(parents=True)
    shutil.copy(RACINE / "tools" / "lancer_victory.ps1", script)
    manifeste = tmp_path / "depot" / "third_party" / "victory" / "Cargo.toml"
    manifeste.parent.mkdir(parents=True)
    manifeste.write_text("", encoding="utf-8")
    jeu = tmp_path / "jeu"
    jeu.mkdir()
    (jeu / "game_scarlett_master.exe").write_bytes(b"")
    cible, outils = tmp_path / "cible", tmp_path / "outils"
    (cible / "diag").mkdir(parents=True)
    outils.mkdir()
    shutil.copy(faux_outil, cible / "diag" / "victory.exe")      # compilation déjà présente (peut-être périmée)
    shutil.copy(faux_outil, outils / "cargo.exe")
    journal = tmp_path / "appels.log"
    env = {**os.environ, "PATH": f"{outils}{os.pathsep}{os.environ['PATH']}", "CARGO_TARGET_DIR": str(cible),
           "FAKE_TOOL_LOG": str(journal), "FAKE_TOOL_EXIT_CARGO": str(code_cargo),
           "FAKE_TOOL_EXIT_VICTORY": str(CODE_SORTIE_VICTORY)}
    env.pop("VICTORY_CARD_REHASH_RUNS", None)
    fini = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
                           "-GameDir", str(jeu), *options], env=env, capture_output=True, text=True, timeout=120)
    appels = journal.read_text(encoding="utf-8").splitlines() if journal.is_file() else []
    return fini, appels, manifeste, jeu


def test_launcher_rebuilds_and_passes_opt_in_card_rehash(tmp_path, faux_outil):
    # Après une mise à jour de third_party/victory, l'ancien victory.exe ignorait les réglages du commit épinglé : cargo décide.
    fini, appels, manifeste, jeu = _lancer(tmp_path, faux_outil)
    assert [a.split()[0] for a in appels] == ["cargo", "victory"], (appels, fini.stderr)
    assert appels[0] == f"cargo build --profile diag -p victory --features diagnostics --manifest-path {manifeste}"
    assert appels[1] == f"victory run {jeu / 'game_scarlett_master.exe'} --execute"
    assert fini.returncode == CODE_SORTIE_VICTORY
    assert "card rehash runs: unset" in fini.stdout.splitlines()

    fini, _, _, _ = _lancer(tmp_path / "rehash", faux_outil, options=("-BatchCardRehash", "-NoTunedSettings"))
    assert fini.returncode == CODE_SORTIE_VICTORY, fini.stderr
    assert "card rehash runs: 1" in fini.stdout.splitlines()


def test_launcher_stops_when_the_build_fails(tmp_path, faux_outil):
    fini, appels, _, _ = _lancer(tmp_path, faux_outil, code_cargo=CODE_ECHEC_CARGO)
    assert [a.split()[0] for a in appels] == ["cargo"], appels         # l'ancien victory.exe n'est pas lancé
    assert fini.returncode != 0
    assert f"cargo build failed (exit code {CODE_ECHEC_CARGO})" in fini.stderr


def test_no_xg_library_in_the_repository():
    # Règle 1 d'AGENTS.md : la xg_xs.dll du GDK vient de la copie de l'utilisateur, jamais du dépôt.
    sortie = subprocess.run(["git", "ls-files", "*.dll"], cwd=RACINE, capture_output=True, text=True,
                            check=False).stdout
    assert "xg_xs" not in sortie.lower()


def test_precompile_runs_translate_before_the_game_with_the_same_environment():
    texte = _lanceur()
    assert "[switch]$Precompile" in texte
    bloc = texte[texte.index("if ($Precompile) {"):texte.index("& $exe run")]
    assert "translate --cache --pipelines --used-pipelines $shaders $gameExe @dlls" in bloc
    assert "shaders.rpf" in bloc and "XboxBvhBuilder.dll" in bloc and "amd_fidelityfx_upscaler_xbox.dll" in bloc
    assert "throw" in bloc
    # Les variables du jeu (clé du cache) sont posées avant la précompilation, pas après.
    assert texte.index("$env:VICTORY_GAME_DIR =") < texte.index("if ($Precompile) {")
    assert texte.index("if ($Precompile) {") < texte.index("& $exe run")


def test_precompile_is_off_by_default():
    texte = _lanceur()
    assert "[switch]$Precompile" in texte and "Precompile = $true" not in texte
