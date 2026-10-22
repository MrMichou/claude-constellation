# claude-constellation

Fond d'écran animé pour AwesomeWM : chaque session Claude Code active apparaît comme un nœud lumineux. Les ressources qu'elle manipule (fichiers, commandes shell, recherches, web, serveurs MCP, subagents) gravitent autour d'elle.

- **Nœud** : pulse selon l'état de la session. Bleu accent pour `thinking`, couleur du type d'outil pour `tool`, jaune clignotant pour une permission en attente, gris pour `done`/`idle`. La session est atténuée après 10 min d'inactivité et masquée après 3 h.
- **Emote Clawd** : comme dans [claude-status-bar](https://github.com/MrMichou/claude-status-bar-awesomewm), chaque nœud affiche un crabe animé selon l'état : *thinking*, *typing* pendant un outil, *listening* en attente de permission, *birthday* pendant 30 s après la fin d'un tour, *sleeping* quand la session est inactive. Artwork : [xixicc186/clawd-emotes-skill](https://github.com/xixicc186/clawd-emotes-skill).
- **Satellites** : les 10 dernières cibles de la session. Leur lien s'estompe sur 5 min, et une impulsion parcourt le lien à chaque appel d'outil.
- **Couleurs par type** : file = bleu, shell = vert, search = cyan, web = magenta, agent = jaune, mcp = rouge.

## Fonctionnement

- `hooks/track.js` est un hook Claude Code. Il écrit `~/.claude/constellation/<session_id>.json` (état, outil, cible, historique) et supprime le fichier à `SessionEnd`.
- `awesome/claude_constellation/` est le module Lua : `render.lua` dessine (cairo, sans dépendance à Awesome), `init.lua` l'intègre à Awesome, `saver.lua` l'anime sur l'écran de verrouillage. Il crée une wibox `type = "desktop"` sous toutes les fenêtres, sur l'écran principal, et dessine en Cairo. Il tourne à 30 fps quand une session travaille, à 8 fps sinon.
- **Sur batterie** (batterie système en `Discharging`), seuls les emotes Clawd restent animés : la dérive, la pulsation, les orbites et les impulsions sont figées, et le redessin est plafonné à 8 fps. Mettre `ON_BATTERY = "off"` dans `init.lua` pour masquer complètement la couche sur batterie.

## Installation

```sh
node install.js            # hooks dans ~/.claude/settings.json + symlink du module
# puis dans ~/.config/awesome/rc.lua, après beautiful.init(...) mais AVANT require("ui")
# (sinon la couche bureau recouvre la barre) :
#   pcall(require, "ui.desktop.claude_constellation")
echo 'awesome.restart()' | awesome-client
```

### Écran de verrouillage animé (xsecurelock)

`lock()` verrouille l'écran sur la constellation animée via [xsecurelock](https://github.com/google/xsecurelock) (`pacman -S xsecurelock`) : `saver.lua` (Lua 5.4 + lgi) dessine dans la fenêtre de verrouillage avec le même moteur (`render.lua`) que le fond d'écran, en mode privé (pas de chemins, commandes ni outil en cours, l'écran verrouillé étant visible par tous) et avec la même règle batterie. xsecurelock garde la main sur l'authentification : si le saver plante, l'écran reste verrouillé. Sans xsecurelock, `lock()` retombe sur une image fixe pour i3lock (`snapshot(path, private)`).

```lua
awful.key({ modkey }, "l", function()
  local ok, cc = pcall(require, "ui.desktop.claude_constellation")
  if ok and cc.lock then cc.lock() else awful.spawn({ "i3lock", "-c", "000000" }) end
end)
```

Les couleurs du thème Awesome sont écrites dans `~/.cache/claude-constellation/theme.json` pour que le saver, qui tourne hors d'Awesome, utilise la même palette.

Pour désinstaller : `node install.js --uninstall`, puis retirer la ligne ajoutée dans `rc.lua`.
