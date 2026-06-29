# Telegram Bot Setup

## Create your bot (2 minutes)

1. Open Telegram and search for **@BotFather**
2. Send: `/newbot`
3. Enter a display name — e.g. `YanivWorkshopBot`
4. Enter a username — must end in `bot`, e.g. `yaniv_workshop_bot`
5. BotFather replies with your **bot token** — looks like:
   ```
   7412345678:AAFxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   Copy it. This is your `TELEGRAM_BOT_TOKEN`.

## Get your chat ID

1. Search for **@userinfobot** in Telegram
2. Send it any message
3. It replies with your **Id** — e.g. `123456789`
   This is your `TELEGRAM_CHAT_ID`.

## ⚠️ Critical: Start your bot before testing

**Telegram blocks bots from sending messages to users who have never contacted them.**

Before running any test:
1. Open Telegram
2. Search for your bot by username (e.g. `@yaniv_workshop_bot`)
3. Tap **START** or send `/start`

This is a one-time step. Without it, every API call returns:
```json
{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}
```

## Add to your workshop setup

Run the setup menu and choose option 3:
```bash
cd ~/n8nWorkShop/student-env
./setup.sh
# Choose: 3) Configure API keys
```

Enter your bot token and chat ID when prompted.

## Test your bot

After starting the stack (option 4), test with:
```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "text=Workshop bot is alive 🚀"
```

You should receive the message on your phone immediately.
