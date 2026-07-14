package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jakobevangelista/runsync/server/internal/api"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/config"
	"github.com/jakobevangelista/runsync/server/internal/database"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "runsync:", err)
		os.Exit(1)
	}
}
func run(args []string) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "serve":
		return serve()
	case "migrate":
		return withPool(func(ctx context.Context, p *pgxpool.Pool) error { return database.Migrate(ctx, p) })
	case "admin":
		if len(args) < 2 {
			return usage()
		}
		return admin(args[1:])
	default:
		return usage()
	}
}
func usage() error {
	return errors.New("usage: runsync serve|migrate|admin bootstrap-owner|admin configure-channel|admin create-credential|admin revoke-credential")
}
func withPool(fn func(context.Context, *pgxpool.Pool) error) error {
	url, err := config.DatabaseURL()
	if err != nil {
		return err
	}
	if url == "" {
		return errors.New("RUNSYNC_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := database.Open(ctx, url, 4)
	if err != nil {
		return err
	}
	defer pool.Close()
	return fn(ctx, pool)
}
func serve() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	pool, err := database.Open(ctx, cfg.DatabaseURL, cfg.DatabaseMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()
	handler := api.New(pool, cfg.ViewerSigningKey, cfg.AllowedOrigins, cfg.TrustedProxies, logger).Handler()
	server := &http.Server{Addr: cfg.HTTPAddress, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, IdleTimeout: 75 * time.Second, MaxHeaderBytes: 16 << 10}
	errs := make(chan error, 1)
	go func() { logger.Info("server listening", "address", cfg.HTTPAddress); errs <- server.ListenAndServe() }()
	select {
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
		shutdown, c := context.WithTimeout(context.Background(), 15*time.Second)
		defer c()
		return server.Shutdown(shutdown)
	}
}
func admin(args []string) error {
	switch args[0] {
	case "bootstrap-owner":
		fs := flag.NewFlagSet("bootstrap-owner", flag.ContinueOnError)
		handle := fs.String("handle", "owner", "owner handle")
		slug := fs.String("channel-slug", "live", "stable channel slug")
		name := fs.String("channel-name", "RunSync Live", "channel display name")
		policy := fs.String("location-policy", "hidden", "hidden, precise, or rounded")
		decimals := fs.Int("coordinate-decimals", -1, "0..6 for rounded location")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		coordinateDecimals, err := validateLocationPolicy(*policy, *decimals)
		if err != nil {
			return err
		}
		return withPool(func(ctx context.Context, p *pgxpool.Pool) error {
			tx, err := p.Begin(ctx)
			if err != nil {
				return err
			}
			defer tx.Rollback(ctx) //nolint:errcheck
			id := uuid.New()
			tag, err := tx.Exec(ctx, `INSERT INTO users(id,handle) VALUES($1,$2) ON CONFLICT(handle) DO NOTHING`, id, *handle)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return fmt.Errorf("owner %q already exists", *handle)
			}
			if _, err = tx.Exec(ctx, `INSERT INTO live_channels(id,user_id,slug,display_name,location_policy,coordinate_decimals) VALUES($1,$2,$3,$4,$5,$6)`, uuid.New(), id, *slug, *name, *policy, coordinateDecimals); err != nil {
				return err
			}
			if err = tx.Commit(ctx); err != nil {
				return err
			}
			fmt.Printf("owner_id=%s channel_slug=%s\n", id, *slug)
			return nil
		})
	case "configure-channel":
		return configureChannel(args[1:])
	case "create-credential":
		return createCredential(args[1:])
	case "revoke-credential":
		return revokeCredential(args[1:])
	default:
		return usage()
	}
}

func configureChannel(args []string) error {
	fs := flag.NewFlagSet("configure-channel", flag.ContinueOnError)
	handle := fs.String("owner", "owner", "owner handle")
	slug := fs.String("slug", "live", "channel slug")
	policy := fs.String("location-policy", "hidden", "hidden, precise, or rounded")
	decimals := fs.Int("coordinate-decimals", -1, "0..6 for rounded location")
	if err := fs.Parse(args); err != nil {
		return err
	}
	coordinateDecimals, err := validateLocationPolicy(*policy, *decimals)
	if err != nil {
		return err
	}
	return withPool(func(ctx context.Context, p *pgxpool.Pool) error {
		tag, err := p.Exec(ctx, `UPDATE live_channels c SET location_policy=$1,coordinate_decimals=$2,updated_at=now() FROM users u WHERE c.user_id=u.id AND u.handle=$3 AND c.slug=$4 AND u.disabled_at IS NULL`, *policy, coordinateDecimals, *handle, *slug)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return errors.New("channel not found")
		}
		fmt.Printf("channel=%s location_policy=%s\n", *slug, *policy)
		return nil
	})
}

func validateLocationPolicy(policy string, decimals int) (*int16, error) {
	switch policy {
	case "hidden", "precise":
		if decimals != -1 {
			return nil, errors.New("--coordinate-decimals is valid only with rounded policy")
		}
		return nil, nil
	case "rounded":
		if decimals < 0 || decimals > 6 {
			return nil, errors.New("rounded policy requires --coordinate-decimals between 0 and 6")
		}
		value := int16(decimals)
		return &value, nil
	default:
		return nil, errors.New("--location-policy must be hidden, precise, or rounded")
	}
}
func createCredential(args []string) error {
	fs := flag.NewFlagSet("create-credential", flag.ContinueOnError)
	handle := fs.String("owner", "owner", "owner handle")
	name := fs.String("name", "", "credential name")
	scopeText := fs.String("scopes", "", "comma-separated scopes")
	expires := fs.Duration("expires-in", 0, "optional validity duration")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" || *scopeText == "" {
		return errors.New("--name and --scopes are required")
	}
	scopes := strings.Split(*scopeText, ",")
	valid := map[string]bool{"telemetry:write": true, "channels:read": true, "channels:manage": true, "activities:read": true, "activities:delete": true}
	for _, v := range scopes {
		if !valid[v] {
			return fmt.Errorf("invalid scope %q", v)
		}
	}
	return withPool(func(ctx context.Context, p *pgxpool.Pool) error {
		var user uuid.UUID
		if err := p.QueryRow(ctx, `SELECT id FROM users WHERE handle=$1 AND disabled_at IS NULL`, *handle).Scan(&user); err != nil {
			return fmt.Errorf("find owner: %w", err)
		}
		token, prefix, hash, err := auth.GenerateToken()
		if err != nil {
			return err
		}
		var expiresAt *time.Time
		if *expires > 0 {
			v := time.Now().Add(*expires)
			expiresAt = &v
		}
		_, err = p.Exec(ctx, `INSERT INTO api_credentials(id,user_id,name,token_prefix,token_hash,scopes,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)`, uuid.New(), user, *name, prefix, hash, scopes, expiresAt)
		if err != nil {
			return err
		}
		fmt.Printf("token=%s\n", token)
		return nil
	})
}
func revokeCredential(args []string) error {
	fs := flag.NewFlagSet("revoke-credential", flag.ContinueOnError)
	id := fs.String("id", "", "credential UUID")
	prefix := fs.String("prefix", "", "credential token prefix")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if (*id == "") == (*prefix == "") {
		return errors.New("provide exactly one of --id or --prefix")
	}
	return withPool(func(ctx context.Context, p *pgxpool.Pool) error {
		var tag pgconn.CommandTag
		var err error
		if *id != "" {
			parsed, e := uuid.Parse(*id)
			if e != nil {
				return e
			}
			tag, err = p.Exec(ctx, `UPDATE api_credentials SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1`, parsed)
		} else {
			tag, err = p.Exec(ctx, `UPDATE api_credentials SET revoked_at=COALESCE(revoked_at,now()) WHERE token_prefix=$1`, *prefix)
		}
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return errors.New("credential not found")
		}
		fmt.Println("credential revoked")
		return nil
	})
}
