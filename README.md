# claude-constellation

Fond d'écran animé pour AwesomeWM : chaque session Claude Code active apparaît comme un nœud lumineux. Les ressources qu'elle manipule (fichiers, commandes shell, recherches, web, serveurs MCP, subagents) gravitent autour d'elle.

- **Nœud** : pulse selon l'état de la session. Bleu accent pour `thinking`, couleur du type d'outil pour `tool`, jaune clignotant pour une permission en attente, gris pour `done`/`idle`. La session est atténuée après 10 min d'inactivité et masquée après 3 h.
- **Emote Clawd** : comme dans [claude-status-bar](https://github.com/MrMichou/claude-status-bar-awesomewm), chaque nœud affiche un crabe animé selon l'état : *thinking*, *typing* pendant un outil, *listening* en attente de permission, *birthday* pendant 30 s après la fin d'un tour, *sleeping* quand la session est inactive. Artwork : [xixicc186/clawd-emotes-skill](https://github.com/xixicc186/clawd-emotes-skill).
- **Satellites** : les 10 dernières cibles de la session. Leur lien s'estompe sur 5 min, et une impulsion parcourt le lien à chaque appel d'outil.
- **Couleurs par type** : file = bleu, shell = vert, search = cyan, web = magenta, agent = jaune, mcp = rouge.

## Fonctionnement

- `hooks/track.js` est un hook Claude Code. Il écrit `~/.claude/constellation/<session_id>.json` (état, outil, cible, historique) et supprime le fichier à `SessionEnd`.
- `awesome/claude_constellation/` est le module Lua. Il crée une wibox `type = "desktop"` sous toutes les fenêtres, sur l'écran principal, et dessine en Cairo. Il tourne à 30 fps quand une session travaille, à 8 fps sinon.
- **Sur batterie** (batterie système en `Discharging`), seuls les emotes Clawd restent animés : la dérive, la pulsation, les orbites et les impulsions sont figées, et le redessin est plafonné à 8 fps. Mettre `ON_BATTERY = "off"` dans `init.lua` pour masquer complètement la couche sur batterie.

## Installation

```sh
node install.js            # hooks dans ~/.claude/settings.json + symlink du module
# puis dans ~/.config/awesome/rc.lua, après beautiful.init(...) mais AVANT require("ui")
# (sinon la couche bureau recouvre la barre) :
#   pcall(require, "ui.desktop.claude_constellation")
echo 'awesome.restart()' | awesome-client
```

### Écran de verrouillage (i3lock)

i3lock couvre tout l'écran, donc pas d'animation possible, mais on peut verrouiller sur une image de la constellation. `snapshot(path, private)` rend l'image à la taille de l'écran racine ; avec `private = true`, les libellés (chemins, commandes) et l'outil en cours sont masqués, puisque l'écran verrouillé est visible par tous :

```lua
awful.key({ modkey }, "l", function()
  local cmd = { "i3lock", "-c", "000000" }
  local img = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/constellation-lock.png"
  local ok, cc = pcall(require, "ui.desktop.claude_constellation")
  if ok and cc.snapshot and cc.snapshot(img, true) then
    table.insert(cmd, "-i"); table.insert(cmd, img)
  end
  awful.spawn(cmd)
end)
```

Pour désinstaller : `node install.js --uninstall`, puis retirer la ligne ajoutée dans `rc.lua`.
