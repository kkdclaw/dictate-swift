# Dictate для macOS (Swift)

Локальная push-to-talk диктовка: зажал горячую клавишу — говоришь — отпустил — текст вставился в активное поле. Полностью офлайн.

Это переписывание [kkdclaw/dictate](https://github.com/kkdclaw/dictate) (Python, v0.22.0) в обычное приложение для Mac: `Dictate.app` в «Программах», без Python, venv и git-клона. Разрешения macOS выдаются самому приложению.

**Статус:** 0.x — функции Python-версии перенесены (хоткей, Whisper со словарём, Parakeet, встроенный распознаватель macOS, стили и LLM-чистка, голосовые команды и сниппеты, капсула, история, «Мой голос»); что нового — `CHANGELOG.md`, справка — меню «Помощь».

## Сборка

Нужен Xcode 27+ (`xcode-select -p` → `/Applications/Xcode.app/…`) и его компилятор Metal (`xcodebuild -downloadComponent MetalToolchain`, ~840 МБ) — для шейдеров MLX.

```sh
./build.sh            # build/Dictate.app
./build.sh --install  # заменить /Applications/Dictate.app и запустить
```

### Подпись

Разрешения macOS (Микрофон, Мониторинг ввода, Универсальный доступ) привязаны к подписи. При подписи ad-hoc macOS узнаёт приложение по хэшу сборки, и после каждой пересборки разрешения приходится выдавать заново. При подписи сертификатом — по сертификату, и разрешения переживают любые пересборки.

`build.sh` сам берёт локальный сертификат «Dictate Local Signing» из связки ключей, если он есть. Доверять ему системе не нужно (`find-identity` покажет `CSSMERR_TP_NOT_TRUSTED` — это нормально). Другой сертификат — `DICTATE_SIGN_ID="Apple Development: …" ./build.sh`.

Создать (один раз на машине; ключ уходит в связку ключей входа, файлы удаляются):

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=Dictate Local Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false"
P=$(openssl rand -hex 12); openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:$P -name "Dictate Local Signing"
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P $P -T /usr/bin/codesign; rm -f key.pem cert.pem id.p12
```

Удалить: `security delete-identity -c "Dictate Local Signing"`. Сменили сертификат — разрешения выдать заново (старые записи: `tccutil reset Accessibility com.kkd.dictate.mac`, то же для `ListenEvent` и `Microphone`).

## План

| Фаза | Что |
|---|---|
| Ф0. Проба | движок распознавания (WhisperKit / whisper.cpp / MLX) против mlx-whisper на реальных записях: скорость, память, словарь в подсказке; подпись и разрешения |
| Ф1. Рабочая версия (0.1) | хоткей, запись, распознавание со словарём и слоями, вставка с возвратом буфера, голосовые команды и сниппеты, история, HUD, мастер разрешений |
| Ф2. Все функции (0.2–0.9) | стили и чистка текста, окно постобработки, «Модели», «Состояние», микрофон после простоя, Parakeet, хранение аудио, статистика |
| Ф3. Переезд (1.0) | автообновление, установка на все машины, Python-версия — точка отката |

## Данные

Форматы как у Python-версии — `terms.txt`, `terms.d/*.txt`, `commands.json`, `config.json`, `history.sqlite3`. Каталог данных — `~/Library/Application Support/Dictate/`. Личные данные в репо не кладутся (`.gitignore`).

Bundle id — `com.kkd.dictate.mac`.
