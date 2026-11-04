// Supabase/PostgREST returns at most 1000 rows per request (the project's
// max-rows setting), silently -- a table that grows past that just loses rows
// on screen. AudacData.all() pages through a query with .range() until it has
// everything, and resolves to the same { data, error } shape as awaiting the
// query directly, so it can wrap any existing call:
//   const { data } = await AudacData.all(client.from('crm_contacts').select('*').order('full_name').order('external_id'));
// Give the query a stable order (a unique column last) so pages don't overlap.
(function () {
  const PAGE = 1000;
  window.AudacData = {
    async all(query, pageSize = PAGE) {
      let rows = [];
      for (let from = 0; ; from += pageSize) {
        const { data, error } = await query.range(from, from + pageSize - 1);
        if (error) return { data: rows.length ? rows : null, error };
        rows = rows.concat(data || []);
        if (!data || data.length < pageSize) return { data: rows, error: null };
      }
    },
  };
})();
