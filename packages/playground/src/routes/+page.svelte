<script lang="ts">
  import { init } from "tql";
  import Playground from "$lib/Playground.svelte";
  async function boot(): Promise<Engine> {
    return init({
      compilation: {
        via: "streaming",
        source: fetch("./tql.wasm"),
      },
    });
  }
</script>
{#await boot()}
<p>loading...</p>
{:then engine}
<Playground {engine}/>
{:catch error}
<p>error</p>
{/await}
