package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"text/template"
	"time"

	"gopkg.in/tucnak/telebot.v2"

	"github.com/LeKovr/go-base/database"
	"github.com/LeKovr/go-base/log"
)

// -----------------------------------------------------------------------------

// Application holds app.Say
type Application struct {
	Config   *Config
	DB       *database.DB
	Log      log.Logger
	bot      *telebot.Bot
	template *template.Template
	messages chan telebot.Message
}

// -----------------------------------------------------------------------------

// Say loads message from template and sais it to chat
func (app Application) Say(code string, chat telebot.Recipient, user Customer, text string) {
	vars := struct {
		Tag  string
		Text string
		User Customer
	}{
		code,
		text,
		user,
	}
	buf := new(bytes.Buffer)
	err := app.template.Execute(buf, vars)
	if err != nil {
		app.Log.Printf("warn: template %s exec error: %+v", code, err)
	} else {
		app.Log.Printf("debug: Send %s(%s) to %+v", code, buf.String(), chat)
		app.bot.Send(chat, buf.String())
	}
}

// -----------------------------------------------------------------------------

// Exec runs external command
func (app Application) Exec(chat telebot.Recipient, cmd ...string) {

	if app.Config.Command == "" {
		app.Say("errNoCmdFile", chat, Customer{}, cmd[0])
		return
	}
	out, err := exec.Command(app.Config.Command, cmd...).Output()
	// Записать в логи результат скрипта
	if err != nil {
		app.Log.Printf("warn: cmd ERROR: %+v (%s)", err, out)
		if err.Error() == "exit status 2" {
			app.Say("errNoCmd", chat, Customer{}, cmd[0])
		} else {
			app.bot.Send(chat, "*ERROR:* "+err.Error(), &telebot.SendOptions{ParseMode: telebot.ModeMarkdown})
		}
	} else {
		app.Log.Printf("warn: cmd OUT: %s", out)
		app.bot.Send(chat, string(out))
	}
}

// loadUser sets Customer fields from telebot.User
func (u *Customer) loadUser(c *telebot.User) {
	u.FirstName = c.FirstName
	u.LastName = c.LastName
	u.Username = c.Username
}

// SetState sets user Disabled state
func (app Application) SetState(state int, chat telebot.Recipient, user Customer) error {

	sql := "update customer set disabled = ? where id = ? and disabled <> ?"
	res, err := app.DB.Engine.Exec(sql, state, user.ID, state)

	s := fmt.Sprintf("%01d", state)
	if err != nil {
		app.Log.Printf("warn: SQL1 error: %s", err.Error())
		app.Say("errState"+s, chat, user, err.Error())
		return err
	}
	aff, err := res.RowsAffected()
	if err != nil {
		app.Log.Printf("warn: SQL2 error: %s", err.Error())
		app.Say("errState"+s, chat, user, err.Error())
		return err
	}

	if aff > 0 {
		app.Say("userState"+s, chat, user, "")
	} else {
		app.Say("userStateKeep", chat, user, "")
	}
	return nil
}

// -----------------------------------------------------------------------------

// Close closes message channel
func (app Application) Close() {
	if app.messages != nil {
		close(app.messages)
	}
}

// -----------------------------------------------------------------------------

// Run does the deal
func (app *Application) Run() {

	bot, err := telebot.NewBot(telebot.Settings{
		Token:  app.Config.Token,
		Poller: &telebot.LongPoller{Timeout: 10 * time.Second},
	})
	exitOnError(app.Log, err, "Bot init")
	app.bot = bot

	var tmpl *template.Template
	if app.Config.Template != "" {
		app.Log.Printf("debug: Load template: %s", app.Config.Template)
		tmpl, err = template.ParseFiles(app.Config.Template)
	} else {
		b, _ := Asset("messages.tmpl")
		tmpl, err = template.New("").Parse(string(b))
	}
	exitOnError(app.Log, err, "Template load")
	app.template = tmpl

	app.Log.Printf("info: Using bot: %s (%s)", bot.Me.Username, bot.Me.Recipient())
	c, err := bot.ChatByID(strconv.Itoa(int(app.Config.Group)))
	app.Log.Printf("info: Forwarding to Group: %s (%s)", c.Title, c.Recipient())

	bot.Handle(telebot.OnText, app.Handler)
	bot.Start()
}

// Handler handles received messages
func (app *Application) Handler(message *telebot.Message) {

	group := &telebot.Chat{ID: app.Config.Group, Type: "group"}
	engine := app.DB.Engine

	inChat := message.Chat.ID == app.Config.Group
	app.Log.Printf("debug: Sender: %+v", message.Sender)
	app.Log.Printf("debug: %s: %s", message.Chat.Title, message.Text)
	sender := Customer{ID: int64(message.Sender.ID)}

	has, _ := engine.Get(&sender) // TODO: err
	if !has {
		// new customer or op
		sender.loadUser(message.Sender)

		if _, err := engine.Insert(&sender); err != nil {
			app.Log.Printf("error: User add error: %+v", err)
		}
		//has, err :=
		engine.Get(&sender)
		if !inChat {
			app.Say("info", group, sender, ".new")
		}
	}

	if message.Text == "/hi" {
		// Say Hi to any user
		app.Say("hello", message.Chat, sender, "")

	} else if inChat { // && strings.HasPrefix(message.Text, "/") {
		// group bot commands, always started from /

		if message.Text == "/help" {
			// Operator needs help
			app.Say("helpOp", message.Chat, sender, "")
			return
		}
		// Customer related commands

		// split customer Code & rest
		reply := strings.SplitN(strings.TrimPrefix(message.Text, "/"), " ", 2)
		if len(reply) == 1 {

			_, err := strconv.ParseUint(reply[0], 10, 64)
			if err != nil {
				// run internal command
				app.Say("cmdRequest", message.Chat, sender, reply[0])
				go app.Exec(message.Chat, reply[0])
				return
			}
			// will show customer info
			reply = append(reply, "=")
		}

		c, err := strconv.ParseUint(reply[0], 10, 64)
		if err != nil {
			app.Say("errNoDigit", message.Chat, sender, reply[0])
			return
		}

		var user = Customer{Code: c}
		has, _ := engine.Get(&user) // TODO: err

		if !has {
			// customer not found
			app.Say("errNoUser", message.Chat, sender, reply[0])

		} else if len(reply) == 2 {
			// given customer code & something
			app.Log.Printf("debug: Customer: %+v", user)
			switch reply[1] {
			case "=":
				// customer info requested
				app.Say("info", message.Chat, user, "")
				return
			case "-":
				// lock user
				if app.SetState(1, message.Chat, user) != nil {
					return
				}
			case "+":
				// unlock user
				if app.SetState(0, message.Chat, user) != nil {
					return
				}
			default:
				// forward reply to customer
				chat := &telebot.Chat{ID: user.ID, Type: "private"}
				app.Log.Printf("debug: Send Text(%s) to %+v", reply[1], chat)
				app.bot.Send(chat, reply[1])
			}

			// save log
			rec := Record{ID: user.ID, IDFrom: sender.ID, Message: reply[1]}
			if _, err := engine.Insert(&rec); err != nil {
				app.Log.Printf("error: Record add error: %+v", err)
			}

		}
	} else if !inChat {
		// Message from customer

		if message.Text == "/start" {
			// bot started
			app.Say("welcome", message.Chat, sender, "")
			return
		}

		// other message
		if sender.Disabled < 2 {
			rec := Record{ID: sender.ID, Message: message.Text}
			if _, err := engine.Insert(&rec); err != nil {
				app.Log.Printf("error: Record add error: %+v", err)
			}

			if sender.Disabled < 1 {
				app.bot.Forward(group, message)
			} else {
				app.Say("userLocked", message.Chat, sender, "")
			}
		}
	}
	//		time.Sleep(time.Second) // wait 1 sec always
	//	app.Log.Printf("Exiting")

}

// -----------------------------------------------------------------------------

// Check if str exists in strings slice
func stringExists(strings []string, str string) bool {
	if len(strings) > 0 {
		for _, s := range strings {
			if str == s {
				return true
			}
		}
	}
	return false
}
