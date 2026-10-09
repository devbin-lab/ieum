# Shortcut service marks

The SVG files in `assets/shortcut-services/` identify the destination services
of user-managed project links. Sources differ by asset as listed below and in
`icon-metadata.json`.

## Simple Icons marks

Discord, GitHub, Jira, KakaoTalk, and Notion use Simple Icons 14.15.0.

- Project: https://github.com/simple-icons/simple-icons
- Pinned commit: `5664507081ffb65b5a2a0ed2bf2ee2b3b327cb4e`
- Upstream paths: `icons/notion.svg`, `icons/jira.svg`, `icons/discord.svg`,
  `icons/kakaotalk.svg`, and `icons/github.svg`
- Project license: CC0 1.0 Universal; full text is in `LICENSE.md`.
- Upstream brand sources and guidelines: `icon-metadata.json`.
- These SVG paths are unchanged. The application applies a foreground tint at render
  time, including a contrasting monochrome tint for GitHub and Notion.

## Official full-color marks

The following replacements use files published by the brand owners. They are
subject to the respective brand guidelines rather than the Simple Icons project
license. Their supplied colors and artwork are preserved.

- **Figma** (`figma.svg`):
  https://www.figma.com/using-the-figma-brand/
  - Official download:
    https://static.figma.com/uploads/4fbf4d754dbbc027ba1530205f8747cd97d532e5
  - Archive member:
    `Figma Brand Assets/Figma Icon (Full-color)/Figma Icon (Full-color).svg`
  - The only change is removal of outer transparent canvas space: SVG viewBox
    `0 0 1024 1280` becomes `312 340 400 600`. All path/circle coordinates,
    colors, proportions, and shape data remain unchanged.
- **Google Drive** (`googledrive.svg`):
  https://fonts.gstatic.com/s/i/productlogos/drive_2020q4/v10/192px.svg
  - This SVG is referenced by the official `https://drive.google.com/` page.
  - Brand guidelines:
    https://developers.google.com/workspace/drive/api/guides/branding
  - The downloaded SVG is unchanged.
- **Slack** (`slack.svg`):
  https://a.slack-edge.com/9cc0056/marketing/img/nav/logo.svg
  - This SVG is referenced by the official
    https://slack.com/intl/en-us/media-kit page.
  - Brand resources: https://slack.com/brand-guidelines
  - The downloaded 54 by 54 full-color symbol SVG is unchanged.

The service names and marks belong to their respective owners. Their inclusion
does not imply affiliation, sponsorship, or endorsement. CC0 does not grant
trademark rights; the upstream `DISCLAIMER.md` and respective brand guidelines
apply.

No external image host or favicon request is needed to display these icons.
