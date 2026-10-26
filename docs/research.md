# Исследование функционального референса

Дата среза: 25 октября 2026 года. Исследуемая публичная документация относится к **MadMapper 6**. Точную patch-версию установленного приложения следует брать из локальной разведки в `status.md`; URL документации не доказывает версию локальной установки.

## Метод и достоверность

- **D — документация:** сведения ниже получены из официального руководства и сайта. Это не результаты запуска MadMapper.
- **O — наблюдение:** только воспроизводимый эксперимент с записанными входом, версией, шагами и результатом. Первые ограниченные наблюдения GUI записаны ниже; они не подтверждают всю документированную функцию.
- **H — гипотеза:** предположение, требующее проверки. Внутренняя архитектура MadMapper не исследована и не выводится из пользовательских функций.
- **A — собственное требование:** инженерное решение для самостоятельного приложения. Критерии приёмки в матрице относятся к нему и не являются утверждением о реализации MadMapper.

Официальный индекс был прочитан через HTTPS. Часть страниц не открылась через поисковый просмотрщик, поэтому для них прочитан HTML официального сайта. Загруженные исследовательские копии находятся во временной папке и не входят в репозиторий. Не копировались код, шейдеры, медиаресурсы, проекты или бинарники MadMapper.

## Реестр источников

Все ссылки проверены 25.10.2026. R01/R44 — неверсионированные страницы актуального продукта; R02–R43 — руководство ветки 6. Сведения о точной сборке в них могут отсутствовать.

| ID | Первичный источник | Область |
|---|---|---|
| R01 | [Features](https://madmapper.com/madmapper/features) | Сводный каталог, форматы, интерфейсы, заявленные лимиты |
| R02 | [Оглавление](https://docs.madmapper.com/) | Полный перечень разделов руководства |
| R03 | [Surface Types](https://docs.madmapper.com/madmapper/6/4.-surfaces/surface-types) | Quad, triangle, circle, mask, line, OBJ |
| R04 | [Warping & Geometry](https://docs.madmapper.com/madmapper/6/4.-surfaces/warping-and-geometry) | Corner pinning, mesh, Bézier, раздельные вход и выход |
| R05 | [Surface Groups & Masks](https://docs.madmapper.com/madmapper/6/4.-surfaces/surface-groups-and-masks) | Порядок, группы, внутренние и глобальные маски |
| R06 | [Surface Inspector](https://docs.madmapper.com/madmapper/6/4.-surfaces/surface-inspector) | Цвет, opacity, FX, feather, output, input |
| R07 | [FreeDraw & Lines](https://docs.madmapper.com/madmapper/6/4.-surfaces/freedraw-and-madline) | Редактирование линий |
| R08 | [SVG Import & Animation](https://docs.madmapper.com/madmapper/6/4.-surfaces/svg-import-and-animation) | Векторный импорт |
| R09 | [Assigning Content](https://docs.madmapper.com/madmapper/6/4.-surfaces/assigning-content-to-surfaces) | Назначение источника поверхности |
| R10 | [Video Wall Setup](https://docs.madmapper.com/madmapper/6/4.-surfaces/video-wall-setup) | Раскладка видеостены |
| R11 | [Soft-Edge Blending](https://docs.madmapper.com/madmapper/6/6.-outputs/soft-edge-blending) | Перекрытия и маски с растушёвкой |
| R12 | [Media Bin](https://docs.madmapper.com/madmapper/6/3.-media/media-bin) | Плееры, генераторы, live inputs, montage |
| R13 | [Media Formats & Codecs](https://docs.madmapper.com/madmapper/6/3.-media/media-formats-and-video-codecs) | Декодирование и платформенные различия |
| R14 | [Writing GLSL Materials](https://docs.madmapper.com/madmapper/6/3.-media/writing-custom-glsl-materials) | Шейдерные материалы |
| R15 | [Loopbacks](https://docs.madmapper.com/madmapper/6/6.-outputs/loopback-and-advanced-output-techniques) | Повторное использование выходов |
| R16 | [Scenes & Cues](https://docs.madmapper.com/madmapper/6/10.-timelines/scenes-and-cues) | Снимки и выборочное восстановление |
| R17 | [Timelines & Conductor](https://docs.madmapper.com/madmapper/6/10.-timelines/timelines-overview-and-the-conductor) | Общая временная модель |
| R18 | [Keyframes](https://docs.madmapper.com/madmapper/6/10.-timelines/creating-and-editing-timelines) | Запись и интерполяция |
| R19 | [Track Types](https://docs.madmapper.com/madmapper/6/10.-timelines/track-types-and-inspectors) | Montage, audio, MIDI, OSC, timeline player |
| R20 | [Clips](https://docs.madmapper.com/madmapper/6/10.-timelines/clips) | In/out и повторно используемые фрагменты |
| R21 | [Markers & Follow Actions](https://docs.madmapper.com/madmapper/6/10.-timelines/time-markers-and-follow-actions) | Pause, loop, jump, follow |
| R22 | [Scheduling](https://docs.madmapper.com/madmapper/6/9.-master-settings/scheduling-and-automation) | Расписание, ICS, startup |
| R23 | [OSC & OSC Query](https://docs.madmapper.com/madmapper/6/11.-live-performance-and-control/osc-commands-and-channels-list) | Адреса, типы, discovery |
| R24 | [DMX Fundamentals](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/dmx-fundamentals) | Выходы, universe, sampling |
| R25 | [DMX Fixtures](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/dmx-fixtures) | Definitions, sampling filters, patching |
| R26 | [Moving Lights](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/controlling-moving-lights) | Механические каналы и цвет |
| R27 | [LED Scanner](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/tools-led-scanner) | Оптическое определение координат LED |
| R28 | [Advanced 3D](https://docs.madmapper.com/madmapper/6/4.-surfaces/advanced-3d-and-scanning) | OBJ и калибровочные соответствия |
| R29 | [Space Scanner](https://docs.madmapper.com/madmapper/6/4.-surfaces/tools-space-scanner) | Структурированный свет |
| R30 | [Scanners](https://docs.madmapper.com/madmapper/6/12.-advanced/special-tools-and-auto-calibration) | Space, LED, laser |
| R31 | [Audio Analysis](https://docs.madmapper.com/madmapper/6/9.-master-settings/audio-input-and-beat-detection) | Реактивные сигналы и beat |
| R32 | [Audio Routing](https://docs.madmapper.com/madmapper/6/14.-technical-notes/audio-routing) | Многоканальный вывод и матрица |
| R33 | [Timeline Export](https://docs.madmapper.com/madmapper/6/10.-timelines/exporting-a-timeline-from-the-conductor) | Video, audio, DMX, ILDA |
| R34 | [MadLight Recorder](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/madlight-recorder) | Запись светового выхода |
| R35 | [MiniMad](https://docs.madmapper.com/madmapper/6/6.-outputs/minimad) | Standalone player и ограничения |
| R36 | [Modules](https://docs.madmapper.com/madmapper/6/8.-modules) | Oscillators, router, controls, MIDI/OSC out |
| R37 | [PJLink Extension](https://docs.madmapper.com/madmapper/6/12.-advanced/madprojectorcontrol) | Управление проектором |
| R38 | [Mad AI](https://docs.madmapper.com/madmapper/6/12.-advanced/mad-ai-extension) | Генерация материалов через сервер |
| R39 | [Arduino/Firmata](https://docs.madmapper.com/madmapper/6/12.-advanced/arduino-and-firmata-integration) | Сенсоры и исполнительные устройства |
| R40 | [Project Structure](https://docs.madmapper.com/madmapper/6/2.-the-interface/madmapper-project-file-structure) | Workspace и сбор ресурсов |
| R41 | [Backup & Recovery](https://docs.madmapper.com/madmapper/6/12.-advanced/project-backup-and-recovery) | Autosave, backup, file collect |
| R42 | [Requirements](https://docs.madmapper.com/madmapper/6/13.-setup-and-installation/requirements) | Аппаратные требования |
| R43 | [FAQ v6](https://docs.madmapper.com/madmapper/6/faqs) | Платформы, demo и лицензия |
| R44 | [Laser extension](https://madmapper.com/extensions/madlaser) | Опциональная лазерная подсистема |

## Существенные выводы D

1. [R04](https://docs.madmapper.com/madmapper/6/4.-surfaces/warping-and-geometry): quad поддерживает перспективу, сетку и Bézier; связь входной и выходной сетки можно отключить. Это требует самостоятельных данных UV и выходных вершин.
2. [R05](https://docs.madmapper.com/madmapper/6/4.-surfaces/surface-groups-and-masks): верхняя поверхность списка находится впереди. Группы ограничивают область действия масок; маска слоя и глобальная mask surface имеют разные области влияния.
3. [R11](https://docs.madmapper.com/madmapper/6/6.-outputs/soft-edge-blending): встроенный soft edge относится к quads. Для произвольной границы предлагается внутренняя маска с feather. В матрице это отдельные функции.
4. [R16](https://docs.madmapper.com/madmapper/6/10.-timelines/scenes-and-cues): Scene сохраняет общий снимок, Cue — выбранные параметры. Запуск полного снимка может перезапустить медиа; переходы и непрерывное воспроизведение нужно тестировать независимо.
5. [R17](https://docs.madmapper.com/madmapper/6/10.-timelines/timelines-overview-and-the-conductor): в v6 есть native timeline и Conductor. [R19](https://docs.madmapper.com/madmapper/6/10.-timelines/track-types-and-inspectors) описывает монтажные, аудио, MIDI, OSC и timeline-player дорожки.
6. [R24](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/dmx-fundamentals): с v6 fixtures берут цвет из выходной композиции. Известные ошибки текста страницы (например, противоречивая расшифровка диапазона каналов в соседнем разделе) не превращаются в требования.
7. [R25](https://docs.madmapper.com/madmapper/6/5.-dmx-and-led-mapping/dmx-fixtures): доступны RGB/RGBW/custom, 8/16 бит, slider/expression, порядок LED и фильтрация sampling. Названия и формат `.mmfl` не используются как собственный формат проекта.
8. [R29](https://docs.madmapper.com/madmapper/6/4.-surfaces/tools-space-scanner): Space Scanner формирует калибровочную карту из структурированного света; документация прямо отличает её от создания 3D-модели.
9. [R32](https://docs.madmapper.com/madmapper/6/14.-technical-notes/audio-routing): многоканальное воспроизведение зависит от интерфейса; документирована матрица маршрутизации и один аудиоинтерфейс одновременно. Стереопроверка не доказывает многоканальную совместимость.
10. [R35](https://docs.madmapper.com/madmapper/6/6.-outputs/minimad): MiniMad VIDEO ограничен одним HDMI до 1080p и одним media одновременно; lines, 3D и FX не поддерживаются. Экспорт в самостоятельный плеер не равен совместимости с MiniMad.
11. [R33](https://docs.madmapper.com/madmapper/6/10.-timelines/exporting-a-timeline-from-the-conductor) описывает MadLight Sequence как проприетарный формат. Свой световой recorder должен использовать собственный открытый формат; импорт чужого формата пока не исследован.
12. [R40](https://docs.madmapper.com/madmapper/6/2.-the-interface/madmapper-project-file-structure): v6 использует workspace `.madproject`; переносимость достигается сбором внешних ресурсов. Это пользовательское поведение, а не разрешение копировать формат.

## Неопределённости и ограничения

- [Features](https://madmapper.com/madmapper/features) и [software](https://madmapper.com/madmapper/software) говорят macOS 11+, а [FAQ v6](https://docs.madmapper.com/madmapper/6/faqs) сохраняет macOS 10.13. Для зависимости или собственного minimum deployment target нужно измерение; конфликт не разрешён догадкой.
- Точная версия протокола sACN на features обозначена кратко; это не заменяет проверку конкретных E1.31 PDU, приоритета, sequence и sync по стандарту.
- Заявленные производителем пределы разрешений, universes и FPS не являются измерениями собственного приложения и не используются в его рекламных обещаниях.
- Для Syphon, Spout, NDI, Blackmagic, Canon, USB-DMX, depth cameras, контроллеров, MiniMad и laser DAC нужны отдельные сборки SDK/драйверов и оборудование. Наличие пункта в документации не доказывает доступность на обеих ОС.
- Копирование онлайн-библиотеки материалов, реализации Mad AI и проприетарных проектов не входит в исследование. Можно реализовать собственный material editor и опциональный провайдер генерации.
- Каталог в `feature-matrix.md` покрывает все разделы текущего официального оглавления, но полнота до каждого пункта меню конкретной patch-сборки ещё не подтверждена black-box аудитом.

## Локальные наблюдения O: MadMapper Demo 6.0.5

Проверено основным агентом через доступный GUI 25.10.2026. Bundle version: **6.0.5**, build **6.0.5.25122226043**. Работа выполнялась с новым пустым тестовым проектом; существующие пользовательские проекты и ресурсы не читались и не изменялись.

| Опыт | Действие / вход | Наблюдаемый результат | Граница доказательства |
|---|---|---|---|
| O01 Demo File menu | Открыть File в Demo 6.0.5 | Open, Save, Save As, Collect, Export и Reveal недоступны; New Project и import media/image folder/3D object/fixtures/SVG lines доступны в меню | Наличие import command не подтверждает успешный импорт конкретного формата |
| O02 Чистый workspace | File → New Project → Video → OK | Создан пустой тестовый Video project, surface list пуст | Не проверены сохранение и формат файлов; demo не даёт такой возможности |
| O03 Toolbar/group | Через accessibility нажать первую кнопку без подписи | Появился `Group-1`; видны Group Color, Opacity, Perspective и Reset | Значение slider accessibility `1000` не интерпретируется как физическая величина без калибровки |
| O04 Ограничение GUI | Попытка дальнейшего клика по координатам screenshot | Инструмент вернул `noWindowsAvailable` | Создание/warping quad этим опытом не подтверждено; дальнейший опыт нужно повторить |

Ни одно из этих наблюдений не даёт основания делать выводы об алгоритмах рендера, внутреннем формате, устройстве undo или доступности лицензированного сохранения. Demo ограничения не обходились.

## Протокол будущих black-box экспериментов

Для каждого опыта создать новый тестовый workspace вне пользовательских проектов. Записать дату, точную версию, demo/full, ОС, GPU, список дисплеев, fixture/SDK; сохранить только собственный вход и текстовый журнал. Менять один параметр за опыт. Минимальные серии: Q01 независимость input/output, Q02 перспектива сетки, Q03 порядок двух alpha-слоёв, Q04 область маски группы, T01 pause/seek/loop и restart Cue, P01 save/reopen/missing media, N01 OSC/Art-Net loopback, H01 отключение output/device. Сравнение внутренних файлов допустимо только для собственных минимальных проектов и без обхода лицензионных ограничений.

## Уточнение primitive/mesh документации: 26.10.2026 (D)

R03/R04 повторно прочитаны по HTTP: поисковый parser выдавал ошибки, обычный HTML был доступен. Это сведения руководства ветки 6, без нового black-box подтверждения точных параметров Demo 6.0.5.

- [Surface Types, R03](https://docs.madmapper.com/madmapper/6/4.-surfaces/surface-types): Circle имеет четыре ручки формы и отдельную центральную ручку перспективы. Описан также путь Quad → Mesh Warping → Sphereize с добавлением warp points. В ApertureCue alpha 3 есть ellipse в общей четырёхугольной рамке; отдельная центральная ручка и Sphereize отсутствуют.
- В том же источнике Triangle можно создавать, изменять размер и поворачивать. Он не устанавливает модель трёх независимых вершин/UV. Поэтому отсутствие такого редактора обозначено ограничением нашей реализации, без утверждения о доказанном поведении MadMapper.
- [Warping & Geometry, R04](https://docs.madmapper.com/madmapper/6/4.-surfaces/warping-and-geometry): описаны shape mask controls и Bézier, добавление/удаление mesh points/lines, групповое выделение, pixel nudge, Precision и включённая по умолчанию связь input/output. Наши primitive surface shapes не заменяют эти mask controls, регулярная mesh не заменяет произвольную топологию, а независимые input/output не означают реализацию link. G04/G11/G13–G15 остаются частичными или открытыми согласно матрице.
