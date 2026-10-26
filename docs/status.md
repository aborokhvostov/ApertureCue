# Текущее состояние ApertureCue

Обновлено: 26 октября 2026 (Europe/Moscow), macOS first. Исследование начато 25 октября. Полное функциональное равенство MadMapper **не достигнуто**. Задача продолжается по [roadmap](roadmap.md); [матрица](feature-matrix.md) различает исследование, реализацию, автоматические, ручные и аппаратные проверки.

## Окружение и референс

- macOS 26.6.2 build 25G83, MacBook Air M2, GPU Apple M2 10 cores, 8 GiB RAM, arm64.
- Apple Swift 6.3.3 / Apple clang 21, Command Line Tools; Qt, CMake и FFmpeg не установлены. Нативная сборка не загружает внешние зависимости.
- Установлен MadMapper **Demo 6.0.5**, bundle build `6.0.5.25122226043`. GUI доступен. В отдельном новом тестовом Video-проекте проверены пустой список поверхностей и создание группы. В Demo пункты Open/Save/Collect/Export отключены. Подробности O01–O04 в [research](research.md).
- Публичные материалы исследованы для ветки MadMapper 6: 44 источника, 84 строки каталога. Это широкий первоначальный каталог, не доказанный исчерпывающий перечень всех меню и параметров конкретной patch-версии.
- [Исходники опубликованы](https://github.com/aborokhvostov/ApertureCue), [prerelease alpha 2](https://github.com/aborokhvostov/ApertureCue/releases/tag/v0.1.0-alpha.2) опубликован для `12a23567ac8966e5909f32e049ffdfbfbc3059f1`. [ZIP и проверка архива](verification/distribution.md); alpha 1 сохранён в истории. Исходный локальный репозиторий был пуст, remote отсутствовал. Поиск точного `ApertureCue` в web и GitHub не дал совпадений; это не юридическая проверка товарного знака.
- Внешние проекторы/свет/MIDI hardware не подтверждены. Camera adapter проверен по отказу, захват реального устройства не проверен. Локальный графический сеанс может использовать виртуальный дисплей.

## Реализованный работающий subset

AppKit editor, Metal compositor, PNG/images и AVFoundation video, quad/triangle/ellipse в четырёхугольной перспективной рамке, independent input/output, projective homography, regular mesh, source-UV polygon mask, local shape feather и antialias, normal/add/multiply/screen, brightness/gamma/RGB, layer ordering, label groups, undo/redo, schema v2 JSON с v0/v1 quad migration, relative media paths, atomic save, named-project recovery, missing-media fallback и relink.

Отдельные output windows с display selection/routing/blackout; surface-only snapshot transitions/follow; persisted linear parameter tracks с компактным редактором; latest-frame AVCapture adapter; fixed MIDI input profile, OSC localhost control с bounded main-thread mailbox; basic RGB/GRB/RGBW strips, asynchronous composition sampling, simulator и opt-in IPv4 ArtDmx/sACN. OBJ импортируется как статическая pinhole-проекция в editable quad patches, без depth buffer и сохранения исходной 3D-сцены. PNG still export.

## Проверки

| Проверка | Фактический результат / границы |
|---|---|
| Portable core | `bash scripts/test-core.sh`: **43 methods, 0 failed assertions**. Те же тела проверок, что в XCTest, выполнены собственным standalone harness: локальный CLT не содержит XCTest. Не выдаётся за запуск XCTest. |
| GPU/media | **35 PASS** на production Metal/AVFoundation. [JSON](verification/self-test.json): homography CPU/GPU ±2/255, image orientation/alpha, blend/masks/feather, mesh, routing/blackout, async sampling, H.264 MOV play/pause/seek/loop, oversized/nonfinite/rapid seek, frame ownership, missing/same-path-restored media, camera failure; triangle/ellipse area/AA/crop/perspective/mesh/mask/feather. Seek tolerance 80 ms; не гарантирован один кадр. |
| Короткий drawable benchmark до primitive-этапа | [JSON](verification/live-benchmark.json): 1280×720 drawable, 4 procedural surfaces, 1 output, 300/300 commands, 5.0005 s, 59.994 submissions/s, 0 skipped. GPU mean 0.456 ms/max 3.379 ms; CPU submit mean 0.297 ms; process CPU 5.09% от одного ядра; peak sampled RSS 54.00 MB. Без video decode. Не измеряет оптическую частоту/4K/длительную стабильность. |
| Native app bundle | Native build/signature PASS. [Editor integration](verification/editor-test.json): **13 PASS**: реальные методы редактора, сохранение сцены с dormant automation, media/history/new/open/recovery, real hidden output constructor, fullscreen frame/level/Escape; shape creation/selector/history/picking и schema-2 save/open. |
| Пошаговый GUI | [Журнал](verification/gui-workflow.md): импорт PNG/MOV, независимый drag input/output, Undo/Redo, Pause/Seek, fullscreen выбранного встроенного дисплея/Escape, quit/relaunch/reopen, SIGKILL отдельной тестовой копии и восстановление реального autosave. Дополнительный [журнал форм](verification/shape-workflow.md): triangle/ellipse cage edits, полный Input, fullscreen и quit/relaunch/reopen schema 2. Это GUI-проверка агентом, не внешний projector H. |
| UDP/MIDI integration | OSC immediate-bundle UDP localhost + MIDI parser PASS. [Lighting pipeline](verification/lighting-test.json): **11 PASS**, GPU sampling → actual ArtDmx/sACN UDP, RGB/GRB/RGBW, automation/routing/blackout, source port 6454, ordinary-zero + 3 sACN termination packets, cancellation/restart. Реальные устройства не проверены. |
| Remote CI | [Проверенный запуск для 12a2356](https://github.com/aborokhvostov/ApertureCue/actions/runs/40287890970): macOS SwiftPM build, XCTest, native bundle/artifact и Linux **38 XCTest** — PASS. Ранние macOS ошибки notification API исправлены по стабильным именам. Также весь app type-check прошёл локально с macOS 15.4 SDK. Fullscreen/scene/relink исправления входят в этот успешный запуск. Изменения primitive/schema 2 проходят следующий CI; отчёты 43/35/13 относятся к локальному development source после alpha 2. Windows desktop/CI отсутствуют. |

SwiftPM локально не линкует `PackageDescription` из-за несогласованного установленного toolchain. `scripts/build.sh` собирает те же source напрямую `swiftc`, app и собственную dylib подписывает ad hoc. Это реальный обход сбойного build frontend, без изменения системного toolchain. Notarization и universal binary не выполнены.

Portable Collect проверен отдельными core tests: проект открывается с копиями после удаления оригиналов, дублирующиеся имена не конфликтуют, missing media откатывает только собственную staging folder, существующая destination не перезаписывается, camera IDs сохраняются. ZIP включает приложение, исходно сгенерированный demo, LICENSE и notices. Упаковка выполняется в системной временной папке без File Provider/AppleDouble metadata.

## Незавершённое

Базовый desktop workflow проверен автоматически и через GUI на текущем дисплее. Открыты: длительный soak, точный multi-source timing/PTS/drift, стабильные display IDs/hotplug, внешние проекторы; graphical timeline/selective cues/montage, дополнительные surface types/Bézier/group transforms, полноценный edge blending, audio engine/routing/analysis, расширенные fixtures/recording, external SDK adapters, live 3D/calibration/scanner, offline video/light export и standalone player, Windows/Linux desktop.

Alpha 2 опубликован после успешного CI, проверки подписи и исполнения редакторских тестов из распакованного ZIP. Следующая задача выпуска — CI и совпадающая сборка primitive/schema-2 этапа. Следующий незавершённый инженерный этап — группы с реальными transforms, линии/Bézier и дальнейшее разделение show runtime для полноценного timeline. Отсутствие оборудования удерживает H gates открытыми; это не мешает дальнейшей программной реализации и не означает аппаратной совместимости.
