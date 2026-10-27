# Каталог функций и матрица покрытия

Референс: официальная документация **MadMapper 6**, срез 25.10.2026. Источники Rxx раскрыты ссылками в [research.md](research.md). Все строки имеют источник D (документация), а критерии — самостоятельные требования A. Источник не подтверждает идентичность поведения реализации.

Статусы независимы: **D** исследовано по документации; **I** реализовано; **A** автоматическая проверка; **M** пошаговая GUI-проверка агентом (см. [журнал](verification/gui-workflow.md)); **H** проверка с реальным устройством; **—** не подтверждено. I partial обозначает работающий заявленный subset, а не выполнение всего критерия строки. Доказательства A и точные ограничения собраны в [status.md](status.md), [core tests](../Tests/MappingCoreTests/) и [GPU report](verification/self-test.json). Ни simulation, ни loopback не дают H. Актуальная проверенная сборка и ограничения — в [status.md](status.md).

Во всех строках версия источника — 6, кроме R01 (актуальная страница без patch-привязки). «ПК» означает текущий компьютер без дополнительного оборудования; GPU, дисплеи и устройства требуют отдельного учёта в отчёте производительности.

## Геометрия и редактирование

| ID / функция / источник | Сценарий; вход → результат | Границы | Платформа / оборудование | Приёмка собственной реализации | Статус |
|---|---|---|---|---|---|
| G01 Quad, R03/R04 | Подогнать изображение; 4 вершины → поверхность | Совпавшие, вогнутые, пересечённые точки | ПК/GPU | Сохранённый quad повторно открывается с теми же вершинами | D · I · A (core) · M (GUI) |
| G02 Input/output, R04/R09 | Выбрать фрагмент; UV и output → crop без сдвига формы | UV вне [0,1], flip, aspect ratio | ПК/GPU | Изменение UV не меняет output и наоборот | D · I · A (GPU) · M (GUI) |
| G03 Perspective, R04 | Подогнать плоскость; прямоугольник → проективный quad | Нулевая площадь, горизонт w=0 | ПК/GPU | Контрольная сетка совпадает с эталонной homography; singular отклоняется | D · I · A (GPU ±2/255) · M (GUI) |
| G04 Triangle/circle, R03 | Геометрическая маска; точки/радиус → покрытие | Нулевой радиус, граница, AA | ПК/GPU | Центр/углы/внешние пиксели имеют ожидаемую alpha | D · I partial: canonical triangle/ellipse in quad cage · A (core + GPU area/AA/crop/mesh/mask/feather) · M (GUI); no center perspective handle/Sphereize; own free three-vertex editor absent (reference UV model unconfirmed) |
| G05 Lines/FreeDraw, R07 | Обвести контур; polyline/Bézier → текстурная полоса | Острые стыки, caps, самопересечение | ПК/GPU | Тесты толщины и стыков на фиксированном разрешении | D · I partial: textured polyline/cubic, independent tangents/nodes, round caps/joins, nearest-arclength UV, bounded local flattening; freehand/alternate joins absent · A (core + GPU + editor) · M ([stroke workflow](verification/stroke-workflow.md)) |
| G06 Transform/snapping, R01/R03 | Точная раскладка; drag/nudge → translation/scale/rotation | Отрицательный масштаб, zoom, DPI | ПК | Обратная команда восстанавливает координаты; snapping имеет явный допуск | D · I partial: corner drag + 5% snap; numeric group translate/rotate/scale/mirror · A (core + GPU + editor) · M (group transform/Undo/Redo) |
| G07 Selection/lock, R06/R24 | Не сдвинуть готовую сцену; selection/lock → ограничение редактирования | Группы, скрытые объекты | ПК | Заблокированный объект не меняется drag/nudge; unlock обратим | D · I partial: selection; lock absent |
| G08 Groups, R05 | Перемещать набор; hierarchy → общий transform/opacity | Цикл, вложение, reparent | ПК/GPU | Relative positions сохраняются; циклический parent запрещён | D · I partial: UUID hierarchy, affine/shear, inherited per-layer opacity/visibility, reparent/dissolve · A (core + GPU + editor); shared group definitions outside surface scenes; group perspective/isolation/FX absent · M ([group workflow](verification/group-workflow.md)) |
| G09 Layer order, R05 | Составить изображение; stack → предсказуемое перекрытие | Alpha=0/1, одинаковые геометрии | ПК/GPU | Два тестовых цвета дают вычисленную композицию в нужном порядке | D · I · A (GPU) |
| G10 Undo/redo, R01 | Исправить правку; command → прежнее/новое состояние | Drag coalescing, branch after undo | ПК | Серия edit/undo/redo и save/reopen сохраняет документ | D · I · A (core) · M (GUI) |
| G11 Mesh, R04 | Искривить плоскость; grid → деформированная поверхность | Foldovers, UV continuity, subdivision | ПК/GPU | Контрольные узлы попадают в эталон; нет трещин между ячейками | D · I partial: regular mesh · A (GPU) |
| G12 Bézier mesh, R04 | Сгладить арку; tangents/precision → кривая | Unlinked tangents, экстремальная кривизна | ПК/GPU | Погрешность tessellation ниже 0.5 px при заданном масштабе | D |
| G13 Mesh link, R04 | Согласовать сетки; link toggle → связанное/раздельное редактирование | Link после разных сеток | ПК | Смена output меняет input только в явно включённом режиме | D |
| G14 Internal/global masks, R05 | Исключить окно; path/scope → alpha cutout | Несколько масок, holes, group scope | ПК/GPU | Маска слоя не затрагивает соседний; групповая не выходит за группу | D · I partial: one source polygon · A (GPU) |
| G15 Bézier masks, R05 | Обвести органический объект; handles → гладкая граница | Незакрытый path, winding | ПК/GPU | AA-эталон и hit-test совпадают с одним правилом заполнения | D |
| G16 Feather, R06/R11 | Смягчить край; ширина → alpha gradient | Нулевая ширина, corners, scaling | ПК/GPU | Alpha монотонна; 0 даёт жёсткий край без NaN | D · I · A (GPU) |
| G17 Edge blend, R11 | Сшить проекторы; overlap/width/power → ослабленные края | Нет overlap, gamma, black level | Два output; физические проекторы для H | Сумма парных ramp равна единице в симуляции; реальный seam измеряется отдельно | D |
| G18 SVG, R08/R13 | Внести вектор; собственный SVG → линии/растровый источник | Transforms, units, unsupported elements | ПК/GPU | Поддерживаемое подмножество задокументировано и проверено golden image | D |
| G19 Video wall, R10 | Разложить grid outputs; rows/cols → набор областей | Bezel, разные размеры | Несколько дисплеев для H | Tiles покрывают заданный canvas без пропусков и двойных индексов | D |

## Медиа, цвет и внешние источники

| ID / функция / источник | Сценарий; вход → результат | Границы | Платформа / оборудование | Приёмка собственной реализации | Статус |
|---|---|---|---|---|---|
| V01 Images, R12/R13 | Импорт тестовой картинки; файл → texture | Alpha, EXIF, HDR, повреждение | ПК/GPU; codecs зависят от сборки | Собственные RGB/alpha patterns дают ожидаемые пиксели | D · I · A (PNG alpha/orientation) · M (GUI import) |
| V02 Video decode, R13 | Проиграть клип; container/codec → кадры PTS | VFR, rotation, EOF, decoder failure | ПК; acceleration платформенная | Локальный тестовый клип декодируется; фактические codecs перечислены | D · I · A (H.264/MOV) · M (GUI import/play) |
| V03 Transport, R12 | Play/pause/seek/loop; time → нужный кадр | Seek до/после duration, pause seek | ПК | Clock и PTS укладываются в один frame interval; pause стабилен | D · I partial · A (80 ms seek) · M (GUI play/pause/seek); no frame lock |
| V04 Modes/speed, R12 | Hold/ping-pong/random/in-out; mode → последовательность кадров | Reverse, zero speed, узкий loop | ПК | Детерминированный PTS trace соответствует выбранному режиму | D |
| V05 Image sequence, R12/R13 | Проиграть folder; сортировка/FPS/cache → video | Нули в имени, gaps, добавление файла | ПК/SSD | Порядок и пропуски определены; cache ограничен | D |
| V06 Media bin/relink, R12/R41 | Найти/заменить ресурс; path → назначенный source | Missing file, одинаковые имена | ПК | Missing media видимо; relink сохраняет назначения и геометрию | D · I · A (missing/same-path relink) · M (GUI import/assignment) |
| V07 Color/opacity/blend, R06 | Изменить вид слоя; RGBA/FX → composition | Premultiplication, linear/sRGB | ПК/GPU | Golden tests normal/add/multiply и alpha с оговорённым color space | D · I · A (normal/add/multiply/screen, 8-bit unorm) |
| V08 Key/FX, R01/R06 | Удалить фон; threshold/effect → обработанный слой | Spill, threshold edges, precision | ПК/GPU | Chroma/luma и поддерживаемые FX имеют численный pixel oracle | D |
| V09 Generators, R12 | Тестировать без media; time/params → grid/color/text/pattern | Pause, resize, одинаковое время | ПК/GPU | Одинаковые seed/time/params дают одинаковый кадр | D · I partial: checker/grid/gradient/solid · A (GPU) |
| V10 Material editor, R14 | Создать собственный shader; code/params → GPU visual | Compile error, GPU timeout, includes | ПК/GPU; API платформенный | Ошибка не рушит проект; последний исправный shader остаётся доступен | D |
| V11 ISF/library, R12/R14 | Импорт открытого материала; licensed source → параметры | Неизвестный extension, unsafe path | ПК/GPU | Только объявленное подмножество; provenance каждого распространяемого asset | D |
| V12 Camera, R12/R01 | Live feed; device frames → media | Denied permission, unplug, format change | AVFoundation macOS / иной backend | Симулятор отдельно; H требует реального устройства и журнал disconnect | D · I · A (unavailable/unauthorized); H absent |
| V13 Syphon, R01/R12 | Texture sharing; server → media/output | Server gone, formats, GPU ownership | macOS + опциональный SDK | Loopback между двумя процессами без роста ресурсов | D |
| V14 Spout, R01/R12 | Texture sharing; sender → media/output | Adapter mismatch, lost sender | Windows + опциональный SDK | Отдельный Windows loopback и реальное GPU измерение | D |
| V15 NDI, R01/R12 | Сетевой video; stream → media/output | Timeout, YUV range, clock drift | Опциональный SDK/network | Sender/receiver test с описанными SDK license и latency | D |
| V16 Blackmagic/Canon, R01 | Специализированный ввод; device → frames | Driver, разрешение, device busy | Опциональный vendor SDK/устройство | Только конкретная модель и драйвер после реального теста | D |
| V17 Depth/legacy sources, R01 | Дополнительные sources; Kinect/RealSense/Quartz → данные | Устаревший SDK/ОС | Устройства/платформенные модули | Каждый backend проходит отдельный capability test; неизвестное недоступно | D |

## Выходы и шоу

| ID / функция / источник | Сценарий; вход → результат | Границы | Платформа / оборудование | Приёмка собственной реализации | Статус |
|---|---|---|---|---|---|
| O01 Output window, R01/R11 | Вывести проектор; screen/mode → clean fullscreen | Retina, смена layout, один display | macOS сначала; внешний экран для H | Editor и output отдельны; Escape закрывает output; screen назначается явно | D · I · A (hidden constructor/Escape) · M (native built-in display); projector H absent |
| O02 Multiple outputs, R01 | Разные области; routes → независимые окна | Разные FPS/DPI, hotplug | GPU/дисплеи | Два окна имеют разные content/routes; disconnect не теряет проект | D · I · A (route filtering); multiwindow M pending; H absent |
| O03 Preview/test pattern, R01/R11 | Настроить без проектора; selection/view → preview | Aspect ratio, overlays, output resolution | ПК/GPU | Preview соответствует output render без editor handles | D · I · A (production renderer) · M (GUI) |
| O04 Loopback/buffers, R15 | Повторно обработать результат; output → source | Цикл, feedback history | ПК/GPU | Цикл либо явно one-frame delayed, либо запрещён; нет deadlock | D |
| O05 Master/freeze/blackout, R23 | Быстро управлять шоу; level/freeze → состояние выхода | Продолжение audio/time, recover | ПК | Семантика freeze определена; blackout даёт чёрный и возвращается обратимо | D · I partial: blackout · A (GPU) |
| S01 Scene snapshot, R16 | Восстановить сцену; whole state → scene | Missing resource, transport restart | ПК | Snapshot восстанавливает все заявленные поля без утечки ссылок | D · I partial: surfaces only · A (core) |
| S02 Selective Cue, R16 | Изменить часть шоу; selected params → partial state | Deleted target, running movie | ПК | Невключённые параметры и текущий media clock сохраняются | D · I partial: 13 surface field masks, native Capture/Save/Recapture editor · A (core + native editor/H.264) · M ([selective workflow](verification/selective-workflow.md)) |
| S03 Transitions, R16 | Плавно перейти; duration/curve → interpolation | 0 seconds, interrupt, discrete fields | ПК/GPU | Значения t=0/mid/end верны; interrupt берёт фактический текущий state | D · I partial: linear compatible fields · A (core) |
| S04 Timeline/keyframes, R17/R18 | Автоматизировать параметр; keys/time → value | Duplicate time, seek, reverse | ПК | Hold/linear/Bezier оцениваются детерминированно | D · I partial: six scalar tracks, graphical keys/Bezier handles, Hold/Linear/Bezier, compiled master clock/loop/continuation and armed inspector recording · A (core + editor/output/light) · M ([timeline workflow](verification/timeline-workflow.md), [recording workflow](verification/recording-workflow.md)) |
| S05 Conductor/banks, R17/R23 | Управлять шоу; bank/cell → parallel timelines | Row exclusivity, bank change | ПК | Конфликты имеют явное правило; запускаемый timeline не дублируется | D |
| S06 Montage/clips, R19/R20 | Смонтировать источники; clips/in-out → media stream | Gap black/skip, overlap crossfade | ПК/GPU/SSD | Clip boundary и crossfade проверены по PTS и pixel oracle | D |
| S07 Markers/follow, R21 | Остановиться до GO; marker → pause/loop/jump | Jump cycle, missed marker after seek | ПК | Event fires once per crossing; cycle budget исключает зависание | D · I partial: scene follow plus timeline Pause/Scene markers, strict crossing/seek policy, bounded queue · A (core + editor) · M ([timeline workflow](verification/timeline-workflow.md)); jump chains absent |
| S08 OSC/MIDI tracks, R19 | Запустить внешнее событие; timed values → messages | Seek replay policy, dropped connection | Network / MIDI | Timestamp trace и loopback совпадают с event policy | D |
| S09 Schedule/ICS/startup, R22 | Шоу по календарю; local times/ICS → Cue | DST, repeated event, reboot, conflicts | ПК/clock | Проверка fake clock, timezone, recurrence, duplicate suppression | D |

## Протоколы, свет и аппаратные модули

| ID / функция / источник | Сценарий; вход → результат | Границы | Платформа / оборудование | Приёмка собственной реализации | Статус |
|---|---|---|---|---|---|
| N01 MIDI in/out, R01/R19/R36 | Контроллер параметров; CC/note/clock → command | 14-bit, running status, unplug | OS MIDI; устройство для H | Codec/virtual port tests; HW только после реального контроллера | D · I partial: fixed input profile · A (MIDI parser); H absent |
| N02 OSC in/out, R23 | Сетевой control; typed packet → parameter/event | Malformed padding, bundle, type mismatch | UDP network | Golden packets, bounds validation и localhost roundtrip | D · I partial: localhost input/immediate bundles · A (codec + UDP) |
| N03 OSC Query, R23 | Найти параметры; HTTP/WS/discovery → tree | Reconnect, renamed ID, unknown path | Network/Bonjour | Независимый client читает типы/ranges/current values и updates | D |
| N04 Art-Net, R01/R24 | Свет по сети; DMX universes → ArtDMX | Endianness, universe index, sequence wrap | Ethernet/node для H | Encode/decode golden packets; UDP loopback и node test раздельно | D · I partial: ArtDmx output · A (codec + GPU/UDP/stop/source-port); H absent |
| N05 sACN, R01/R24 | Свет по E1.31; universe slots → PDU | Priority, CID, sequence, terminate, sync | Ethernet/node для H | Длины/flags/vector и независимый receiver; multicast отдельно | D · I partial: unicast data/termination · A (codec + GPU/UDP/stop); H absent |
| N06 Synchronization, R01/R17 | Общий темп/время; Link/MIDI/timecode → clocks | Drift, loss, reconnect | Optional Link/timecode backend | Измеренная межпроцессная phase error; наличие play broadcast недостаточно | D |
| L01 Pixel sampling, R24/R25 | LED повторяют video; output+sample coords → RGB | Outside canvas, filtering, gamma | ПК; LEDs для H | Собственная RGB-карта даёт точные bytes при nearest/box | D · I (320×180 nearest) · A (full GPU → UDP chain) |
| L02 Patch/fixture editor, R25 | Описать свет; definition/address → channel map | 512 boundary, overlap, invalid channel | ПК | Validation и явный conflict; roundtrip собственного fixture format | D · I partial: strip patch · A (core validation) |
| L03 RGBW/custom/16bit, R25 | Управлять сложным прибором; channels → slots | Coarse/fine, reserved, CMY | ПК; fixture для H | 0/mid/max и порядок байтов подтверждены oracle | D · I partial: RGB/GRB/RGBW · A (core) |
| L04 LED layout, R25 | Полоса/матрица; dimensions/order → sample/address grid | Serpentine, skip, unpatched pixels | ПК | Каждое patched pixel имеет уникальный ожидаемый index | D · I partial: line strip · A (core) |
| L05 Moving lights, R26 | Цвет из video, pan из automation; map+sliders → DMX | Manufacturer mode/range | Реальный прибор только после simulator | Fixture-specific channel trace; движение на реальном приборе отдельно | D |
| L06 CSV/SVG layout, R25 | Внести большую схему; file → fixtures/groups | Header mismatch, duplicate address | ПК | Импорт атомарен; невалидный row даёт точную диагностику | D |
| L07 DMX monitor/router, R24/R36 | Проверить маршрут; network/universe → monitor/USB | Feedback loop, stale input | ПК/USB-DMX optional | Monitor совпадает с packet trace; routing cycle исключён | D · I partial: raw-channel simulator · A (sampling without network); router absent |
| L08 Light record/play, R34 | Запечь show; sampled bytes/time → open sequence | Clock rate, gaps, disk error | ПК | Record/replay bytes и время совпадают в допуске одного frame | D |
| L09 LED scanner, R27 | Найти координаты; flash sequence+camera → layout | Occlusion, missed LED, ambient flicker | Камера + LED rig | Синтетический image stack test отдельно от физической калибровки | D |
| L10 USB-DMX/SPI, R01/R24 | Физический вывод; universes → adapter | Driver, unplug, device busy | Vendor/open adapter module | Каждая модель отдельно; simulation не объявляется совместимостью | D |
| H01 3D OBJ/UV/light, R28 | Проецировать на объект; mesh/UV → rendered model | Bad indices, normals, huge file | ПК/GPU | Собственный mesh test, depth/UV golden frames, bounded parser | D · I partial: OBJ→static quad patches · A (core); no depth renderer |
| H02 3D calibration, R28 | Сопоставить точки; 3D↔2D pairs → camera/RMS | Coplanar, outlier, few points | Модель; projector для H | Синтетическая известная камера восстанавливается с заявленной RMS | D |
| H03 Space Scanner, R29 | Построить фон настройки; patterns/captures → calibration map | Saturation, motion, timing | Камера + projector | Synthetic structured-light decode; реальная map отдельно | D |
| H04 PJLink, R37 | Power/mute remotely; IP/auth → desired state+feedback | Cooling, timeout, auth, standby network | PJLink projector | Simulator state-machine tests и physical model test отдельно | D |
| H05 Arduino/Firmata, R39 | Sensors/outputs; pin messages → params | Serial drop, board reset, unsafe ranges | Optional serial + board | Virtual serial loopback; board/firmware documented for H | D |
| H06 Control surfaces, R36/R01 | Исполнение Cue; pads/feedback → actions | Device mapping, bank/state feedback | Supported MIDI/gamepad/Stream Deck | Virtual controls test; каждый профиль устройства отдельно | D |
| H07 Modules/oscillators, R36 | Реактивные связи; signals/combiner → params | Cyclic graph, NaN, CPU budget | ПК | Fixed-time deterministic signal tests и cycle detection | D |
| H08 Laser/ILDA, R30/R33/R44 | Векторный show; paths → preview/ILDA/DAC | Point density, blanking, safety zones | Optional extension/DAC/projector | Offline simulator/export сначала; никакого laser H без отдельного стенда | D |
| H09 AI generation, R38 | Создать shader; prompt/provider → source | Privacy, credits, bad generated code | Опциональный внешний service | Provider independent adapter; compile validation; base работает offline | D |

## Аудио, экспорт и проект

| ID / функция / источник | Сценарий; вход → результат | Границы | Платформа / оборудование | Приёмка собственной реализации | Статус |
|---|---|---|---|---|---|
| A01 Audio playback, R12/R32 | Звук к show; channels/time → audio | Device loss, sample rate, mute | OS audio | Собственный tone clip, pause/seek; drift измерен | D · I partial: AVPlayer system audio; audio test absent |
| A02 Routing matrix, R32 | Развести каналы; matrix → device channels | Unavailable outputs, clipping | Многоканальный интерфейс для H | Offline matrix oracle; реальные каналы проверены отдельно | D |
| A03 Analysis/beat, R31 | Реактивный visual; PCM → bands/envelope/BPM | Silence, clipping, changing tempo | Audio input optional | Synthetic tones/pulse train; BPM error и latency опубликованы | D |
| E01 Offline render, R33 | Экспортировать show; duration/FPS → frames/video/audio | VFR, missing sources, cancel, disk full | Codec backend/SSD | Deterministic frame count, timestamps и own golden frames | D |
| E02 Light/ILDA export, R33/R34 | Передать standalone data; timeline → open files | Unsupported effects, sample rate | ПК; optional player | Документированный собственный формат и roundtrip; MiniMad не подразумевается | D |
| E03 MiniMad/standalone, R35 | Автономное шоу; export → external player | Unsupported surfaces/FX, media count | MiniMad для его H | Свой player имеет собственную спецификацию; vendor protocol не заявляется | D |
| P01 Versioned project, R40 (сценарий) | Сохранить show; model → own file → model | Future version, corrupt data, relative paths | ПК | Atomic save, schema/migration tests; unsupported version не перезаписывается | D · I · A (core) · M (GUI save/quit/reopen) |
| P02 Recovery/backups, R41 | Восстановить после crash; autosave → recovered document | Disk full, interrupted save, stale recovery | ПК | Kill/restart test; основной сохранённый файл остаётся валиден | D · I partial: named sidecar · A · M (GUI SIGKILL/restore/save); power-loss untested |
| P03 Resource collect, R40/R41 | Перенести шоу; references → portable folder | Colliding names, symlink, absent resource | ПК/SSD | Копия открывается после перемещения без обращения к исходной папке | D · I · A (collect rollback/no-overwrite/independent copy) |

## Неизвестное и правила покрытия

Это каталог исследованных областей, а не сертификат полного функционального равенства. Точные меню, все параметры FX, интеграции depth/legacy SDK, библиотека устройств, patch-specific regressions и proprietary project/MiniMad форматы требуют дальнейших опытов. Каждая I/A/M/H должна ссылаться на исходник, test/report или журнал оборудования. Простой UI control, описание архитектуры или доступный SDK не дают I. Пропущенная функция остаётся незавершённым этапом roadmap.
