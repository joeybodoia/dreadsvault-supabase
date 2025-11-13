

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  user_email text;
  user_username text;
begin
  -- get email from auth.users
  user_email := new.email;

  -- get username from metadata (optional, if provided)
  user_username := new.raw_user_meta_data ->> 'username';

  insert into public.users (id, email, username, join_date)
  values (new.id, user_email, user_username, now());

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user_with_credits"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  user_count INTEGER;
  initial_credit NUMERIC(10, 2) := 0.00;
BEGIN
  -- Count existing users
  SELECT COUNT(*) INTO user_count FROM users;
  
  -- Grant $10 credit if user count is less than 100
  IF user_count < 100 THEN
    initial_credit := 10.00;
  END IF;
  
  -- Insert new user record with appropriate credit
  INSERT INTO public.users (id, email, username, site_credit)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'username', NULL),
    initial_credit
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    username = COALESCE(EXCLUDED.username, users.username),
    site_credit = COALESCE(users.site_credit, initial_credit);
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."handle_new_user_with_credits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propagate_all_cards_to_chase_slots"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE public.chase_slots cs
  SET
    card_name             = NEW.card_name,
    card_number           = NEW.card_number,
    rarity                = NEW.rarity,
    image_url             = NEW.image_url,
    ungraded_market_price = NEW.ungraded_market_price,
    date_updated          = NEW.date_updated
  WHERE cs.all_card_id = NEW.id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."propagate_all_cards_to_chase_slots"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_chase_slot_card_details"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  r public.all_cards%ROWTYPE;
BEGIN
  -- Only when all_card_id is present
  IF NEW.all_card_id IS NOT NULL THEN
    SELECT * INTO r FROM public.all_cards WHERE id = NEW.all_card_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'all_cards row % not found for chase_slots', NEW.all_card_id;
    END IF;

    NEW.card_name             := r.card_name;
    NEW.card_number           := r.card_number;
    NEW.rarity                := r.rarity;
    NEW.image_url             := r.image_url;
    NEW.ungraded_market_price := r.ungraded_market_price;
    NEW.date_updated          := r.date_updated;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_chase_slot_card_details"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."all_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "card_name" "text" NOT NULL,
    "card_number" "text",
    "set_name" "text",
    "rarity" "text",
    "image_url" "text",
    "ungraded_market_price" numeric(10,2),
    "date_updated" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."all_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chase_bids" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slot_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chase_bids" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."chase_slot_leaders" AS
 SELECT "slot_id",
    "max"("amount") AS "top_bid"
   FROM "public"."chase_bids"
  GROUP BY "slot_id";


ALTER VIEW "public"."chase_slot_leaders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chase_slots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stream_id" "uuid" NOT NULL,
    "set_name" "text" NOT NULL,
    "all_card_id" "uuid" NOT NULL,
    "starting_bid" numeric(12,2) DEFAULT 1 NOT NULL,
    "min_increment" numeric(12,2) DEFAULT 1 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "locked" boolean DEFAULT false NOT NULL,
    "winner_user_id" "uuid",
    "winning_bid_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "card_name" "text",
    "card_number" "text",
    "rarity" "text",
    "image_url" "text",
    "ungraded_market_price" numeric,
    "date_updated" timestamp with time zone
);


ALTER TABLE "public"."chase_slots" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."direct_bid_cards_view" AS
 SELECT "id",
    "card_name",
    "card_number",
    "set_name",
    "rarity",
    "image_url",
    "ungraded_market_price",
    "date_updated"
   FROM "public"."all_cards"
  WHERE ("ungraded_market_price" >= (35)::numeric);


ALTER VIEW "public"."direct_bid_cards_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_singles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stream_id" "uuid",
    "card_name" "text" NOT NULL,
    "set_name" "text",
    "image_url" "text",
    "starting_bid" numeric(12,2) DEFAULT 1 NOT NULL,
    "min_increment" numeric(12,2) DEFAULT 1 NOT NULL,
    "buy_now" numeric(12,2),
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ungraded_market_price" numeric(12,2),
    "psa_10_price" numeric(12,2),
    "card_number" "text",
    "card_condition" "text",
    CONSTRAINT "live_singles_psa_10_price_check" CHECK ((("psa_10_price" IS NULL) OR ("psa_10_price" >= (0)::numeric))),
    CONSTRAINT "live_singles_ungraded_market_price_check" CHECK ((("ungraded_market_price" IS NULL) OR ("ungraded_market_price" >= (0)::numeric)))
);


ALTER TABLE "public"."live_singles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_singles_bids" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "card_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."live_singles_bids" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."live_singles_leaders" AS
 SELECT "card_id",
    "max"("amount") AS "top_bid"
   FROM "public"."live_singles_bids"
  GROUP BY "card_id";


ALTER VIEW "public"."live_singles_leaders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lottery_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "round_id" "uuid",
    "selected_rarity" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "credits_used" smallint,
    "pack_number" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."lottery_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lottery_winners" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "round_id" "uuid",
    "lottery_entry_id" "uuid",
    "winner_position" integer,
    "assigned_packs" integer[],
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "lottery_winners_winner_position_check" CHECK (("winner_position" = ANY (ARRAY[1, 2])))
);


ALTER TABLE "public"."lottery_winners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pulled_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "round_id" "uuid",
    "all_card_id" "uuid",
    "card_name" "text" NOT NULL,
    "card_number" "text",
    "set_name" "text",
    "rarity" "text",
    "image_url" "text",
    "ungraded_market_price" numeric(10,2),
    "date_updated" timestamp with time zone DEFAULT "now"(),
    "pack_number" integer
);


ALTER TABLE "public"."pulled_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rounds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stream_id" "uuid",
    "set_name" "text" NOT NULL,
    "round_number" integer NOT NULL,
    "packs_opened" integer DEFAULT 10 NOT NULL,
    "locked" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "total_packs_planned" integer,
    CONSTRAINT "rounds_round_number_check" CHECK ((("round_number" >= 1) AND ("round_number" <= 3)))
);


ALTER TABLE "public"."rounds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."streams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "scheduled_date" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "singles_close_at" timestamp with time zone,
    "status" "text" DEFAULT 'scheduled'::"text",
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    CONSTRAINT "streams_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'live'::"text", 'ended'::"text"])))
);


ALTER TABLE "public"."streams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "username" "text",
    "email" "text",
    "join_date" "date" DEFAULT CURRENT_DATE,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_admin" boolean DEFAULT false NOT NULL,
    "avatar" "text",
    "site_credit" numeric(12,2) DEFAULT 0,
    CONSTRAINT "users_site_credit_nonneg" CHECK (("site_credit" >= (0)::numeric))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."all_cards"
    ADD CONSTRAINT "all_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chase_bids"
    ADD CONSTRAINT "chase_bids_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chase_slots"
    ADD CONSTRAINT "chase_slots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chase_slots"
    ADD CONSTRAINT "chase_slots_stream_set_card_uniq" UNIQUE ("stream_id", "set_name", "all_card_id");



ALTER TABLE ONLY "public"."live_singles_bids"
    ADD CONSTRAINT "live_singles_bids_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."live_singles"
    ADD CONSTRAINT "live_singles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lottery_entries"
    ADD CONSTRAINT "lottery_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lottery_entries"
    ADD CONSTRAINT "lottery_entries_user_id_round_id_pack_key" UNIQUE ("user_id", "round_id", "pack_number");



ALTER TABLE ONLY "public"."lottery_entries"
    ADD CONSTRAINT "lottery_entries_user_round_pack_uniq" UNIQUE ("user_id", "round_id", "pack_number");



ALTER TABLE ONLY "public"."lottery_winners"
    ADD CONSTRAINT "lottery_winners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lottery_winners"
    ADD CONSTRAINT "lottery_winners_round_id_winner_position_key" UNIQUE ("round_id", "winner_position");



ALTER TABLE ONLY "public"."pulled_cards"
    ADD CONSTRAINT "pulled_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rounds"
    ADD CONSTRAINT "rounds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rounds"
    ADD CONSTRAINT "rounds_stream_set_round_uniq" UNIQUE ("stream_id", "set_name", "round_number");



ALTER TABLE ONLY "public"."streams"
    ADD CONSTRAINT "streams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



CREATE INDEX "chase_bids_slot_id_idx" ON "public"."chase_bids" USING "btree" ("slot_id");



CREATE INDEX "chase_bids_user_id_created_at_idx" ON "public"."chase_bids" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "chase_slots_is_active_idx" ON "public"."chase_slots" USING "btree" ("is_active");



CREATE INDEX "chase_slots_stream_id_set_name_idx" ON "public"."chase_slots" USING "btree" ("stream_id", "set_name");



CREATE INDEX "idx_chase_bids_top" ON "public"."chase_bids" USING "btree" ("slot_id", "amount" DESC);



CREATE INDEX "idx_chase_slots_active_true" ON "public"."chase_slots" USING "btree" ("id") WHERE ("is_active" = true);



CREATE INDEX "idx_chase_slots_all_card_id" ON "public"."chase_slots" USING "btree" ("all_card_id");



CREATE INDEX "idx_chase_slots_card_name_trgm" ON "public"."chase_slots" USING "gin" ("card_name" "public"."gin_trgm_ops");



CREATE INDEX "idx_chase_slots_stream_set_active" ON "public"."chase_slots" USING "btree" ("stream_id", "set_name", "is_active");



CREATE INDEX "idx_chase_slots_stream_set_locked" ON "public"."chase_slots" USING "btree" ("stream_id", "set_name", "locked");



CREATE INDEX "idx_chase_slots_stream_set_price" ON "public"."chase_slots" USING "btree" ("stream_id", "set_name", "ungraded_market_price" DESC);



CREATE INDEX "idx_individual_bids_top" ON "public"."live_singles_bids" USING "btree" ("card_id", "amount" DESC);



CREATE INDEX "idx_live_singles_stream_active_price" ON "public"."live_singles" USING "btree" ("stream_id", "is_active", "ungraded_market_price" DESC);



CREATE INDEX "idx_lottery_round" ON "public"."lottery_entries" USING "btree" ("round_id");



CREATE INDEX "idx_lottery_round_pack" ON "public"."lottery_entries" USING "btree" ("round_id", "pack_number");



CREATE INDEX "idx_lottery_round_pack_rarity" ON "public"."lottery_entries" USING "btree" ("round_id", "pack_number", "selected_rarity");



CREATE INDEX "idx_lottery_round_rarity" ON "public"."lottery_entries" USING "btree" ("round_id", "selected_rarity");



CREATE INDEX "idx_lottery_user" ON "public"."lottery_entries" USING "btree" ("user_id");



CREATE INDEX "idx_pulled_round" ON "public"."pulled_cards" USING "btree" ("round_id");



CREATE INDEX "idx_pulled_round_pack" ON "public"."pulled_cards" USING "btree" ("round_id", "pack_number");



CREATE INDEX "idx_pulled_round_rarity" ON "public"."pulled_cards" USING "btree" ("round_id", "rarity");



CREATE INDEX "live_singles_bids_card_id_idx" ON "public"."live_singles_bids" USING "btree" ("card_id");



CREATE INDEX "live_singles_bids_user_id_created_at_idx" ON "public"."live_singles_bids" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "live_singles_stream_id_is_active_idx" ON "public"."live_singles" USING "btree" ("stream_id", "is_active");



CREATE UNIQUE INDEX "uq_lottery_user_round_pack" ON "public"."lottery_entries" USING "btree" ("user_id", "round_id", "pack_number");



CREATE OR REPLACE TRIGGER "trg_propagate_all_cards_to_chase_slots" AFTER UPDATE OF "card_name", "card_number", "rarity", "image_url", "ungraded_market_price", "date_updated" ON "public"."all_cards" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_all_cards_to_chase_slots"();



CREATE OR REPLACE TRIGGER "trg_sync_chase_slot_card_details" BEFORE INSERT OR UPDATE OF "all_card_id" ON "public"."chase_slots" FOR EACH ROW EXECUTE FUNCTION "public"."sync_chase_slot_card_details"();



ALTER TABLE ONLY "public"."chase_bids"
    ADD CONSTRAINT "chase_bids_slot_id_fkey" FOREIGN KEY ("slot_id") REFERENCES "public"."chase_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chase_bids"
    ADD CONSTRAINT "chase_bids_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chase_slots"
    ADD CONSTRAINT "chase_slots_all_card_id_fkey" FOREIGN KEY ("all_card_id") REFERENCES "public"."all_cards"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."chase_slots"
    ADD CONSTRAINT "chase_slots_stream_id_fkey" FOREIGN KEY ("stream_id") REFERENCES "public"."streams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chase_slots"
    ADD CONSTRAINT "chase_slots_winner_user_id_fkey" FOREIGN KEY ("winner_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."live_singles_bids"
    ADD CONSTRAINT "live_singles_bids_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."live_singles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_singles_bids"
    ADD CONSTRAINT "live_singles_bids_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_singles"
    ADD CONSTRAINT "live_singles_stream_id_fkey" FOREIGN KEY ("stream_id") REFERENCES "public"."streams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lottery_entries"
    ADD CONSTRAINT "lottery_entries_round_id_fkey" FOREIGN KEY ("round_id") REFERENCES "public"."rounds"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lottery_entries"
    ADD CONSTRAINT "lottery_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lottery_winners"
    ADD CONSTRAINT "lottery_winners_lottery_entry_id_fkey" FOREIGN KEY ("lottery_entry_id") REFERENCES "public"."lottery_entries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lottery_winners"
    ADD CONSTRAINT "lottery_winners_round_id_fkey" FOREIGN KEY ("round_id") REFERENCES "public"."rounds"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pulled_cards"
    ADD CONSTRAINT "pulled_cards_all_card_id_fkey" FOREIGN KEY ("all_card_id") REFERENCES "public"."all_cards"("id");



ALTER TABLE ONLY "public"."pulled_cards"
    ADD CONSTRAINT "pulled_cards_round_id_fkey" FOREIGN KEY ("round_id") REFERENCES "public"."rounds"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rounds"
    ADD CONSTRAINT "rounds_stream_id_fkey" FOREIGN KEY ("stream_id") REFERENCES "public"."streams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Admin can read all users" ON "public"."users" FOR SELECT TO "admin_user" USING (true);



CREATE POLICY "Allow all for admin" ON "public"."users" USING (true);



CREATE POLICY "Allow all for dev" ON "public"."users" USING (true) WITH CHECK (true);



CREATE POLICY "Allow insert " ON "public"."streams" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow inserts" ON "public"."rounds" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow service role to view all users" ON "public"."users" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Anyone can read lottery entries" ON "public"."lottery_entries" FOR SELECT USING (true);



CREATE POLICY "Anyone can read lottery winners" ON "public"."lottery_winners" FOR SELECT USING (true);



CREATE POLICY "Anyone can read rounds" ON "public"."rounds" FOR SELECT USING (true);



CREATE POLICY "Anyone can read streams" ON "public"."streams" FOR SELECT USING (true);



CREATE POLICY "Authenticated users can insert their own profile" ON "public"."users" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert own data" ON "public"."users" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert own lottery entries" ON "public"."lottery_entries" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read own data" ON "public"."users" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own credit" ON "public"."users" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own data" ON "public"."users" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own lottery entries" ON "public"."lottery_entries" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."lottery_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lottery_winners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rounds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user_with_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user_with_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user_with_credits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."propagate_all_cards_to_chase_slots"() TO "anon";
GRANT ALL ON FUNCTION "public"."propagate_all_cards_to_chase_slots"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."propagate_all_cards_to_chase_slots"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_chase_slot_card_details"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_chase_slot_card_details"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_chase_slot_card_details"() TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";


















GRANT ALL ON TABLE "public"."all_cards" TO "anon";
GRANT ALL ON TABLE "public"."all_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."all_cards" TO "service_role";



GRANT ALL ON TABLE "public"."chase_bids" TO "anon";
GRANT ALL ON TABLE "public"."chase_bids" TO "authenticated";
GRANT ALL ON TABLE "public"."chase_bids" TO "service_role";



GRANT ALL ON TABLE "public"."chase_slot_leaders" TO "anon";
GRANT ALL ON TABLE "public"."chase_slot_leaders" TO "authenticated";
GRANT ALL ON TABLE "public"."chase_slot_leaders" TO "service_role";



GRANT ALL ON TABLE "public"."chase_slots" TO "anon";
GRANT ALL ON TABLE "public"."chase_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."chase_slots" TO "service_role";



GRANT ALL ON TABLE "public"."direct_bid_cards_view" TO "anon";
GRANT ALL ON TABLE "public"."direct_bid_cards_view" TO "authenticated";
GRANT ALL ON TABLE "public"."direct_bid_cards_view" TO "service_role";



GRANT ALL ON TABLE "public"."live_singles" TO "anon";
GRANT ALL ON TABLE "public"."live_singles" TO "authenticated";
GRANT ALL ON TABLE "public"."live_singles" TO "service_role";



GRANT ALL ON TABLE "public"."live_singles_bids" TO "anon";
GRANT ALL ON TABLE "public"."live_singles_bids" TO "authenticated";
GRANT ALL ON TABLE "public"."live_singles_bids" TO "service_role";



GRANT ALL ON TABLE "public"."live_singles_leaders" TO "anon";
GRANT ALL ON TABLE "public"."live_singles_leaders" TO "authenticated";
GRANT ALL ON TABLE "public"."live_singles_leaders" TO "service_role";



GRANT ALL ON TABLE "public"."lottery_entries" TO "anon";
GRANT ALL ON TABLE "public"."lottery_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."lottery_entries" TO "service_role";



GRANT ALL ON TABLE "public"."lottery_winners" TO "anon";
GRANT ALL ON TABLE "public"."lottery_winners" TO "authenticated";
GRANT ALL ON TABLE "public"."lottery_winners" TO "service_role";



GRANT ALL ON TABLE "public"."pulled_cards" TO "anon";
GRANT ALL ON TABLE "public"."pulled_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."pulled_cards" TO "service_role";



GRANT ALL ON TABLE "public"."rounds" TO "anon";
GRANT ALL ON TABLE "public"."rounds" TO "authenticated";
GRANT ALL ON TABLE "public"."rounds" TO "service_role";



GRANT ALL ON TABLE "public"."streams" TO "anon";
GRANT ALL ON TABLE "public"."streams" TO "authenticated";
GRANT ALL ON TABLE "public"."streams" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";
GRANT SELECT ON TABLE "public"."users" TO "admin_user";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
