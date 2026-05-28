<script lang="ts">
  import { ready } from "$lib/boot";
  import Playground from "$lib/Playground.svelte";
</script>
{#await ready}
<p>loading...</p>
{:then _}
<Playground />
{:catch error}
<p>error {error}</p>
{/await}
