# Руководство пользователя ApertureCue 0.1

Это ранняя настольная сборка для macOS 13+. Точное состояние проверок находится в [status.md](status.md). Описанные ниже рабочие операции не означают полного покрытия MadMapper 6.

## Запуск и демонстрационный проект

Из корня исходников выполните `./scripts/build.sh`, затем `open dist/ApertureCue.app`. Приложение стартует с двумя процедурными поверхностями и двумя сохранёнными вариантами геометрии. Для собственного демонстрационного изображения и видео выполните:

```sh
dist/ApertureCue.app/Contents/MacOS/ApertureCue --generate-demo examples/Demo
dist/ApertureCue.app/Contents/MacOS/ApertureCue examples/Demo/Demo.aperturecue.json
```

Генератор создаёт `calibration.png` 960×540, `motion.mov` H.264 640×360, 30 fps, 3 секунды и `Demo.aperturecue.json`. Это собственные тестовые материалы. При повторном запуске генератора существующий `motion.mov` не заменяется; для независимого опыта выберите новую папку.

## Медиа и поверхности

**Import…** или File → Import Media… (`⌘I`) открывает выбор изображений и видео. При импорте источник назначается выбранной поверхности; если поверхности нет, создаётся новая. Для повторного назначения выберите media слева, затем surface и нажмите **Assign to surface**.

**+ Quad**, **Duplicate**, **Delete** изменяют список поверхностей. Список подписан `back → front`: последующие строки рисуются поверх предыдущих. Кнопки со стрелками меняют порядок. Это собственное соглашение ApertureCue; оно отличается от списка слоёв функционального референса.

В режиме **Output geometry** перетаскивайте четыре угла выбранного quad. Вершины не должны пересекаться или схлопываться. **Shift** включает привязку к сетке 5% canvas. В **Input region** отображается исходное медиа и отдельно редактируется его область выборки. Изменение input не меняет output. Геометрия хранится в нормализованных координатах; изменение размера окна не перемещает поверхность в проекте.

**Reset quad / input** сбрасывает текущую сторону. Изменение output corners после создания warp mesh сбрасывает эту сетку; это ограничение текущего редактора. **Create 4 × 4 warp mesh** создаёт регулярную сетку. **Edit mesh points / Edit quad corners** переключает редактируемые handle points. Полноценные Bézier handles и произвольное добавление узлов относятся к следующим этапам.

## Цвет, маски и группы

Inspector содержит opacity, brightness, gamma, RGB multiplier и режимы normal/add/multiply/screen. **Generator / fallback** выбирает checker, gradient, solid или grid и снимает назначение медиа. Если назначенный ресурс не загрузился, procedural fallback позволяет продолжить настройку; ошибка отображается в нижней строке.

**Add polygon mask** создаёт редактируемую четырёхточечную внутреннюю маску в координатах источника. **Edit polygon mask** включает её handles; **Remove mask** удаляет. Это одна polygon mask на поверхность; Bézier, несколько масок, holes и глобальные mask surfaces ещё не равнозначно реализованы. **Edge feather** смягчает край поверхности; это не автоматическая калибровка seam двух реальных проекторов.

Поле **Group** сейчас задаёт общую метку. **Toggle entire group** переключает видимость всех поверхностей с такой меткой. Иерархических групповых transforms или отдельного compositing buffer текущая метка не создаёт.

## Статический импорт OBJ

File → **Import projected OBJ…** читает polygonal Wavefront OBJ и предлагает camera Z и vertical FOV. Камера смотрит на origin; видимый результат запекается в редактируемые 2D patches, по три quad на каждый triangle. Выбранное media назначается импортированным patches, а OBJ texture V переводится из нижнего левого начала в верхнее левое.

Импорт поддерживает positive/negative indices и planar polygons, но не загружает MTL, внешние textures или исходную 3D-сцену. Чтение/разбор/проекция выполняются в фоне; результат не добавляется в другой документ, если во время работы был выполнен New/Open. UV-degenerate и неподдерживаемая геометрия отклоняются с диагностикой. Static projection ограничена 1365 triangles; ввод — 16 MiB. Triangles сортируются по средней глубине; пересечения не разрешаются depth buffer. Triangle, пересекающий near/far clipping plane, пропускается целиком. Это полезный static mapping path, но не полноценный 3D renderer, calibration или scanner.

## Воспроизведение

**Play/Pause**, **Stop** и slider управляют импортированными видео. Stop ставит на паузу и переводит к началу. Seek в pause должен обновлять кадр, сохраняя pause. В media inspector выбранного видео доступны **Loop ON/OFF**, volume и **Relink media…**. Текущая transport bar общая для media pool; отдельная полнофункциональная плеерная панель на каждый clip ещё не реализована.

Поддержку конкретного файла определяет AVFoundation установленной macOS. Наличие расширения `.mkv`, `.avi` или `.webm` в классификаторе не гарантирует decoder: при ошибке будет показана диагностика. Проверенный тестовый codec/container должен быть указан в status. AVPlayer воспроизводит встроенное аудио через системный вывод; advanced multichannel routing и frame sync нескольких плееров пока не подтверждены.

**Camera…** запрашивает доступ к камере только по действию пользователя и предлагает доступные устройства. Источник назначается выбранной поверхности. Capture backend сохраняет последний кадр, пропускает опоздавшие и выводит диагностику недоступного устройства. Работа без подключённой камеры и сама реализация adapter не подтверждают capture на конкретной модели; доступность/разрешение/отключение проверяются отдельно. Camera source остаётся live при pause movie transport.

## Выход на дисплей

Нажмите **Outputs…**, выберите экран, затем **Open fullscreen** или **Open preview window**. Это отдельное окно с чистой композицией, без handles редактора. **Escape** закрывает output. **Close outputs** закрывает все output windows. **Blackout** делает output чёрным, оставляя редактор доступным для настройки.

В inspector поверхности можно выбрать **All outputs** либо конкретное назначение. Несколько отдельных окон разделяют media textures и имеют свои render targets. Наличие двух окон на одном экране не считается проверкой двух физических проекторов.

Текущие назначения используют индекс экрана; после изменения конфигурации дисплеев повторно откройте Outputs и проверьте назначение. Сохранённые width/height конфигурации не являются отдельным редактором режимов экрана. Не заявляется автоматическое восстановление при hotplug.

## Снимки и управление шоу

В строке **SCENES** кнопка **Capture** сохраняет текущий набор поверхностей с переходом 1 секунда; выберите снимок и нажмите **GO**. Эти снимки включают surface state, а не полный transport/audio/network state. Полноценные selective cues, timeline editor, markers, montage и calendar scheduler пока остаются в roadmap.

Схема проекта позволяет задать snapshot `duration` и необязательный `followAfter` в секундах. Первый параметр — время перехода, второй — задержка до следующего снимка после завершения перехода. Редактирование JSON выполняйте на закрытой копии проекта с сохранённым backup; несоответствующие schema значения будут отклонены.

**Animate…** создаёт для выбранной поверхности линейную дорожку opacity, brightness, gamma, red, green или blue. Введите пары времени и значения, например `0:0, 2:1, 5:0`. Времена должны строго возрастать, opacity находится в 0…1. **Save track** заменяет дорожку того же параметра; **Remove tracks** удаляет все дорожки выбранной поверхности. Дорожки сохраняются в проекте.

Automation вычисляется по monotonic show transport seconds; Play/Pause/Seek меняют это время. Вне диапазона keys удерживается крайнее значение. Это компактный редактор линейных параметров, без graphical timeline, Bézier interpolation, clip montage и loop markers. Автоматизированный параметр имеет приоритет над базовым значением surface/snapshot во время вычисления output.

**Control…** запускает локальный OSC listener и MIDI input только по явной команде. OSC адрес — `127.0.0.1:9000`, UDP. Другой компьютер по сети к этому listener не подключается.

| Адрес OSC | Аргумент | Действие |
|---|---|---|
| `/aperturecue/play` | нет | Play |
| `/aperturecue/pause` | нет | Pause |
| `/aperturecue/seek` | float/int seconds | Seek |
| `/aperturecue/blackout` | int/bool | Включить/выключить blackout |
| `/aperturecue/cue` | int, с нуля | Запустить surface snapshot |
| `/aperturecue/surface/0/opacity` | float 0…1 | Opacity первой поверхности; индекс можно заменить |

MIDI Note On: 60 — play, 61 — pause, 62 — blackout on, 63 — off, 36…59 — снимки с индексом 0…23. CC1 управляет opacity первой поверхности. Это фиксированный текущий профиль, не универсальный mapping editor. Настоящее MIDI-устройство требует отдельной проверки; parser и виртуальный источник не дают аппаратной сертификации. Световой UDP output включается отдельно в LED panel.

## LED mapping и симулятор

**LED…** добавляет линейную fixture по количеству pixels, universe, начальному DMX address и двум нормализованным точкам композиции. Выберите RGB, GRB или RGBW. **Add fixture + simulate** сохраняет layout в проекте и открывает симулятор, не включая отправку в сеть. Адреса каналов начинаются с 1; universe передаётся на провод без автоматического смещения. Fixture не переносится через границу 512 и не перекрывает занятые каналы. Поэтому для RGB при address 1 доступно до 170 pixels, для RGBW — до 128.

Sampling берётся из полной output composition, уменьшенной до 320×180, nearest pixel, с частотой не выше 30 Hz. При занятости GPU/sender кадры пропускаются вместо накопления очереди. Это не фильтрация по площади fixture и не физическая калибровка LED. Симулятор показывает первые raw RGB channel triplets universes; он не декодирует обратно произвольный GRB/RGBW профиль в реальные цвета приборов.

Для отправки задайте числовой IPv4 destination, выберите Art-Net или sACN и нажмите **Start network output**. Порты: Art-Net source/destination 6454, sACN destination 5568. По умолчанию target `127.0.0.1`; отправка включается только явно. При смене target/protocol сначала завершается прежний output, затем применяются новые проверенные settings. **Stop output** останавливает sampling и передаёт нулевые ArtDmx levels либо обычный zero-valued sACN data packet, за которым следуют три packets с Stream Terminated. Это разные действия: receiver игнорирует channel values в terminated packet. **Clear fixtures** сначала останавливает output, затем удаляет layout. Runtime target/protocol не являются сохранёнными полями проекта.

Quit ставит media на паузу, останавливает controls и дожидается очереди lighting Stop с ограничением около одной секунды. Это попытка корректного завершения локальной отправки, а не подтверждение, что UDP packet получен реальным node.

Этот этап поддерживает простые strips и UDP data packets. Полный fixture-definition editor, 16-bit channels, moving lights, protocol discovery/sync, USB-DMX и recorder ещё не закончены. Физическое поведение реального node при blackout/termination требует отдельной проверки. Симулятор и localhost loopback не дают аппаратной совместимости или полной protocol conformance; OEM registration для Art-Net остаётся незавершённой.

## Protocol credits

Art-Net™ Designed by and Copyright Artistic Licence.

Кредит приведён согласно [официальной спецификации Art-Net 4, revision 1.4dp](https://art-net.org.uk/downloads/art-net.pdf), раздел Credits. Дополнительный статус регистрации и границы лицензии — в [third-party notices](../THIRD_PARTY_NOTICES.md).

## Сохранение, история и экспорт

File → Save (`⌘S`) и Save As (`⇧⌘S`) записывают собственный `.aperturecue.json`; Open (`⌘O`) повторно загружает его. Это JSON schema version 1, а не формат MadMapper. Сохраняемые media paths относительны к папке файла; в памяти используются абсолютные пути.

File → **Collect portable project…** создаёт переносимую копию в новой, ещё не существующей папке. Внутри находятся `project.aperturecue.json` и `media/<asset UUID>.<extension>`. Такое именование разделяет одноимённые источники. Приложение копирует обычные media files, проверяет созданный проект и относительные ссылки, затем публикует готовую папку одним переименованием. Missing media, неподходящий source или ошибка копирования отменяют операцию; исходный проект и выбранная папка назначения не перезаписываются.

Collect работает в фоне со снимком текущего проекта. Открытый документ не переключается на копию; более поздние правки не входят в уже начатый сбор. Live camera IDs сохраняются как ссылки на устройства и на другом компьютере могут быть недоступны. Для переноса откройте `project.aperturecue.json` из собранной папки и перемещайте её целиком.

Undo (`⌘Z`) и Redo (`⇧⌘Z`) работают с правками документа. Drag записывается одной операцией. История ограничена 100 снимками, очищается при New/Open и не сериализуется между запусками. Действия внешних устройств и текущее время плеера не являются document undo.

Для изменённого проекта с уже выбранным именем каждые примерно 10 секунд записывается отдельный recovery file `.<project filename>.recovery`. Успешное ручное Save удаляет его. При открытии проекта приложение предлагает восстановление, если recovery найден. Восстановление после реального принудительного завершения должно быть отдельно проверено в status; внешний или оставшийся recovery file не имеет автоматического timestamp freshness filter.

File → Export PNG… (`⌘E`) сохраняет композицию кадра 1920×1080 без handles. Это still export, а не экспорт timeline/movie или standalone show.

## Диагностика

Нижняя строка показывает renderer FPS, время CPU encode, GPU command time, skipped submissions и сообщения media errors. Эти числа не являются процентом загрузки CPU/GPU или точным счётчиком dropped video frames.

Команды диагностики из корня проекта:

```sh
dist/ApertureCue.app/Contents/MacOS/ApertureCue --self-test
dist/ApertureCue.app/Contents/MacOS/ApertureCue --protocol-loopback
dist/ApertureCue.app/Contents/MacOS/ApertureCue --lighting-test
dist/ApertureCue.app/Contents/MacOS/ApertureCue --benchmark
```

`--self-test` создаёт `artifacts/local/self-test.json`: production Metal и короткий собственный H.264 clip. `--protocol-loopback` проверяет локальную UDP доставку OSC и MIDI parser. `--lighting-test` создаёт `artifacts/local/lighting-test.json`: полный GPU → sampling → production sender → настоящий localhost UDP → decoder, включая color order, automation, routing, blackout и simulation без network. `--benchmark` создаёт `artifacts/local/live-benchmark.json` с короткой серией visible drawable submissions.

Эти локальные серии уже выполнялись успешно в текущем окружении; точные counts/revision/date приведены в [status.md](status.md), а сохранённые отчёты — в [verification](verification). Ни один короткий тест не подтверждает длительный show, оптическую частоту проектора, внешний дисплей, физическую fixture или захват конкретной камеры. В benchmark нет video decoding.
