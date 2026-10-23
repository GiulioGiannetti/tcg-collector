-- alerts-daily
select cron.schedule('alerts-daily', '30 14 * * *', 'select public.check_alerts()');

-- bulba-logos
select cron.schedule('bulba-logos', '*/5 * * * *', 'select public.fill_bulba_logos(40); select public.fill_series_logos(); select public.fill_tcgdex_logos(10); select public.fill_bulba_logos_by_code(10); select public.fill_yugipedia_logos(50);');

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

-- images-tcg-pcom
select cron.schedule('images-tcg-pcom', '* * * * *', 'select public.upgrade_images_tcg_pcom(200);');

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

-- pokemon-image-upgrade
select cron.schedule('pokemon-image-upgrade', '*/2 * * * *', 'select public.upgrade_pokemon_images(150)');

-- pokemon-image-upgrade-pcom
select cron.schedule('pokemon-image-upgrade-pcom', '1-59/2 * * * *', 'select public.upgrade_pokemon_images_pcom(150)');

-- portfolio-daily
select cron.schedule('portfolio-daily', '0 14 * * *', 'select public.snapshot_portfolio()');

-- ptcg-alt-images
select cron.schedule('ptcg-alt-images', '*/2 * * * *', 'select probe_ptcg_alt(40)');

-- set-covers-daily
select cron.schedule('set-covers-daily', '45 14 * * *', 'select public.refresh_set_covers()');

-- set-totals-daily
select cron.schedule('set-totals-daily', '17 * * * *', 'refresh materialized view concurrently set_card_totals');

