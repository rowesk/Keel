# Keel

Keel is a macOS browser that prevents parallel browsing by allowing one ordinary page at a time and deferring other destinations.

## Language

**Active page**:
The sole ordinary browsing context available for interaction. Its navigation chain continues until the user finally closes it.
_Avoid_: Live page, tab, active task

**Keel Home**:
The non-web state from which the user starts, resumes, or manages deferred browsing. It is not an active page or a general-purpose dashboard.
_Avoid_: New tab page, dashboard

**Queue**:
A time-bound first-in, first-out collection of destinations waiting behind the active page. It contains no loaded pages, suspended work, or tasks.
_Avoid_: Tabs, tab strip, task list, suspended pages

**Queued destination**:
A URL captured for later with context already known when it entered the queue. It is not a running page, task, or saved browsing session.
_Avoid_: Tab, task, session

**Transactional detour**:
A temporary secondary browsing context required to complete a flow belonging to the active page. It may hold interaction briefly but remains subordinate to that page.
_Avoid_: Second tab, parallel page

**Undo page**:
The most recently closed active page while it remains eligible for one restoration. It is inaccessible unless restored and cannot form a collection.
_Avoid_: Recently closed list, suspended tab, closed-page history

**Resume page**:
A checkpoint of unfinished active-page work offered after Keel launches or recovers. It is not active until the user chooses to restore it.
_Avoid_: Active page, undo page, suspended tab

**History**:
The permanent local record of visits grouped by browsing session. It contains no restorable page state and remains separate from the queue and undo page.
_Avoid_: Undo history, queued destinations, saved sessions

**Browsing session**:
The chain of visits belonging to one active page from opening until final close. Undo and resume continue the same browsing session, while a transactional detour forms a subordinate branch.
_Avoid_: Tab session, website login session, app session

**Scene**:
The still photograph drawn behind Keel Home, either one Keel ships or a copy of one the user imported. It never moves and is not a theme.
_Avoid_: Wallpaper, background image, screensaver, theme

**Home background**:
The Settings block where the user picks the mode and the library of scenes Keel Home draws from. It sets what shows behind Home, not the app's light or dark appearance.
_Avoid_: Wallpaper settings, theme settings, appearance
