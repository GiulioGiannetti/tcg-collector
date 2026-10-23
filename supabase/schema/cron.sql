-- alerts-daily
select cron.schedule('alerts-daily', '30 14 * * *', 'select public.check_alerts()');

-- bulba-logos
select cron.schedule('bulba-logos', '*/5 * * * *', 'select public.fill_bulba_logos(40); select public.fill_series_logos(); select public.fill_tcgdex_logos(10); select public.fill_bulba_logos_by_code(10); select public.fill_yugipedia_logos(50);');

-- card-images
select cron.schedule('card-images', '*/10 * * * *', 'select public.refresh_card_images();');

-- catalog-checks
select cron.schedule('catalog-checks', '41 3 * * *', 'select public.run_catalog_checks(40);');

-- catalog-set-lists
select cron.schedule('catalog-set-lists', '0 17 * * 0', 'select public.sync_set_lists()');

-- catalog-sync-tick
select cron.schedule('catalog-sync-tick', '*/3 * * * *', 'select public.sync_tick(6)');

-- ebay-asking-prices
select cron.schedule('ebay-asking-prices', '*/5 * * * *', 'select public.fetch_ask_prices(15)');

-- ebay-insights-check
select cron.schedule('ebay-insights-check', '0 9 * * *', 'select public.check_insights_access()');

-- fx-hourly
select cron.schedule('fx-hourly', '5 * * * *', 'select public.refresh_fx()');

-- jp-images-limitless
select cron.schedule('jp-images-limitless', '*/3 * * * *', 'select probe_limitless_jp(25)');

-- news-refresh
select cron.schedule('news-refresh', '15 */3 * * *', 'select public.fetch_news()');

-- op-official-logos
select cron.schedule('op-official-logos', '20 15 * * *', 'select op_official_logos(8)');

-- pack-images-daily
select cron.schedule('pack-images-daily', '10 15 * * *', 'select public.fill_onepiece_pack_images(30); select public.fill_dbs_pack_images(); select public.fill_dbs_masters_pack_images(20);');

-- pokemon-enrich-tcgdex
select cron.schedule('pokemon-enrich-tcgdex', '* * * * *', 'select public.enrich_pokemon_cards(30)');

-- portfolio-daily
select cron.schedule('portfolio-daily', '0 14 * * *', 'select public.snapshot_portfolio()');

-- set-covers-daily
select cron.schedule('set-covers-daily', '45 14 * * *', 'select public.refresh_set_covers()');

-- set-totals-daily
select cron.schedule('set-totals-daily', '17 * * * *', 'refresh materialized view concurrently set_card_totals');

-- tcgp-refresh
select cron.schedule('tcgp-refresh', '17 * * * *', 'select public.fill_tcgp_group(group_id) from (select group_id from public.tcgp_groups where set_id is not null and (loaded_at is null or loaded_at < now() - interval ''7 days'') order by loaded_at nulls first limit 6) x');

-- variant-audit
select cron.schedule('variant-audit', '7,22,37,52 * * * *', 'select extensions.http_set_curlopt(''CURLOPT_TIMEOUT'',''15''); select public.audit_variants_batch(40);');

