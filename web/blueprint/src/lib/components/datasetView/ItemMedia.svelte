<script lang="ts">
  import {
    queryDatasetManifest,
    queryDatasetSchema,
    querySettings
  } from '$lib/queries/datasetQueries';
  import {getDatasetViewContext, type ColumnComparisonState} from '$lib/stores/datasetViewStore';
  /**
   * Component that renders a single value from a row in the dataset row view
   * In the case of strings with string_spans, it will render the derived string spans as well
   */
  import {getSettingsContext} from '$lib/stores/settingsStore';
  import {getComputedEmbeddings, getDisplayPath, getSpanValuePaths} from '$lib/view_utils';
  import SvelteMarkdown from 'svelte-markdown';

  import {
    L,
    PATH_WILDCARD,
    formatValue,
    getValueNodes,
    pathIsEqual,
    pathIsMatching,
    petals,
    type DataTypeCasted,
    type LilacField,
    type LilacValueNode,
    type Path
  } from '$lilac';
  import {SkeletonText} from 'carbon-components-svelte';
  import {
    CatalogPublish,
    ChevronDown,
    ChevronUp,
    DataBackup,
    DataView,
    DataViewAlt,
    DirectionFork,
    Search,
    Undo
  } from 'carbon-icons-svelte';
  import ButtonDropdown from '../ButtonDropdown.svelte';
  import {hoverTooltip} from '../common/HoverTooltip';
  import ItemMediaDiff from './ItemMediaDiff.svelte';
  import ItemMediaTextContent from './ItemMediaTextContent.svelte';

  export let mediaPath: Path;
  export let row: LilacValueNode | undefined | null = undefined;
  export let field: LilacField;
  export let highlightedFields: LilacField[];
  // The root path contains the sub-path up to the point of this leaf.
  export let rootPath: Path | undefined = undefined;
  // The showPath is a subset of the path that will be displayed for this node.
  export let showPath: Path | undefined = undefined;
  export let isFetching: boolean | undefined = undefined;

  // Choose the root path which is up to the point of the next repeated value.
  $: firstRepeatedIndex = mediaPath.findIndex(p => p === PATH_WILDCARD);
  $: {
    if (rootPath == null) {
      if (firstRepeatedIndex != -1) {
        rootPath = mediaPath.slice(0, firstRepeatedIndex + 1);
      } else {
        rootPath = mediaPath;
      }
    }
  }

  $: valueNodes = row != null ? getValueNodes(row, rootPath!) : [];
  $: isLeaf = pathIsMatching(mediaPath, rootPath) && valueNodes.length === 1;

  // Get the list of next root paths for children of a repeated node.
  $: nextRootPaths = valueNodes.map(v => {
    const path = L.path(v)!;
    const nextRepeatedIdx = mediaPath.findIndex((p, i) => p === PATH_WILDCARD && i >= path.length);
    const showPath = mediaPath.slice(nextRepeatedIdx).filter(p => p !== PATH_WILDCARD);
    return {
      rootPath: [
        ...path,
        ...mediaPath.slice(path.length, nextRepeatedIdx === -1 ? undefined : nextRepeatedIdx)
      ],
      showPath
    };
  });

  // The child component will communicate this back upwards to this component.
  let textIsOverBudget = false;
  let userExpanded = false;
  // True when the user has switched to preview mode (markdown rendering).
  let userPreview: boolean | undefined = undefined;

  const datasetViewStore = getDatasetViewContext();
  const appSettings = getSettingsContext();

  $: pathForDisplay = showPath != null ? showPath : rootPath!;

  $: displayPath = getDisplayPath(pathForDisplay);

  $: value = L.value(valueNodes[0]) as string;

  $: settings = querySettings($datasetViewStore.namespace, $datasetViewStore.datasetName);

  // Get slots for the view. These are custom UI renderings that are a function of dataset formats.
  $: datasetManifest = queryDatasetManifest(
    $datasetViewStore.namespace,
    $datasetViewStore.datasetName
  );
  $: titleSlots = $datasetManifest.data?.dataset_manifest.dataset_format?.title_slots as [
    Path,
    Path
  ][];
  // Resolve repeated indices from a path by mapping it to the root path.
  function resolveRepeatedIndices(path: Path): Path {
    return path.map((p, i) => {
      if (p === PATH_WILDCARD) {
        return rootPath![i];
      }
      return p;
    });
  }

  // Get the title path for this root path. This returns undefined.
  $: titlePath = (titleSlots || []).find(slot => {
    const [mediaPath] = slot;
    return pathIsEqual(mediaPath, rootPath);
  })?.[1]; // The second value in the tuple is the title path.
  $: titleValue =
    titlePath != null && row != null
      ? L.value(getValueNodes(row, resolveRepeatedIndices(titlePath))[0])
      : null;

  $: schema = queryDatasetSchema($datasetViewStore.namespace, $datasetViewStore.datasetName);
  // Compare media paths should contain media paths with resolved path wildcards as sometimes the
  // user wants to compare items in an array.
  // NOTE: We do not use media paths here to allow the user to compare to a field they didn't
  // necessarily add to the media fields.
  $: stringPetals =
    $schema.data != null ? petals($schema.data).filter(p => p.dtype?.type === 'string') : [];

  $: compareMediaPaths = stringPetals
    .map(f => f.path)
    .map(p => (Array.isArray(p) ? p : [p]))
    .flatMap(p => {
      if (row == null) {
        return [];
      }
      // Get the value nodes for this path, which expand PATH_WILDCARDs.
      return getValueNodes(row!, p)
        .map(v => L.path(v))
        .filter(p => !pathIsMatching(p, rootPath));
    }) as Path[];

  $: compareItems = compareMediaPaths.map(p => ({
    id: p,
    text: getDisplayPath(p)
  }));
  function selectCompareColumn(event: CustomEvent<{id: Path}>) {
    datasetViewStore.addCompareColumn([rootPath!, event.detail.id]);
  }

  $: computedEmbeddings = getComputedEmbeddings($schema.data, mediaPath);
  $: noEmbeddings = computedEmbeddings.length === 0;

  $: spanValuePaths = getSpanValuePaths(field, highlightedFields);

  function findSimilar(searchText: DataTypeCasted) {
    let embedding = computedEmbeddings[0];

    if ($settings.data?.preferred_embedding != null) {
      const preferred = $settings.data.preferred_embedding;
      if (computedEmbeddings.some(v => v === preferred)) {
        embedding = preferred;
      }
    }
    if ($appSettings.embedding != null) {
      const preferred = $appSettings.embedding;
      if (computedEmbeddings.some(v => v === preferred)) {
        embedding = preferred;
      }
    }
    datasetViewStore.addSearch({
      path: field.path,
      type: 'semantic',
      query: searchText as string,
      query_type: 'document',
      embedding
    });
  }
  // Returns the second path of a diff, if a given path is being diffed.
  let colCompareState: ColumnComparisonState | null = null;
  $: {
    colCompareState = null;
    for (const compareCols of $datasetViewStore.compareColumns) {
      if (pathIsEqual(compareCols.column, rootPath)) {
        colCompareState = compareCols;
        break;
      }
    }
  }
  function removeComparison() {
    datasetViewStore.removeCompareColumn(mediaPath);
  }
  $: datasetSettingsMarkdown =
    $settings.data?.ui?.markdown_paths?.find(p => pathIsEqual(p, mediaPath)) != null;
  $: viewType = $settings.data?.ui?.view_type || 'single_item';

  $: markdown = userPreview !== undefined ? userPreview : datasetSettingsMarkdown;
</script>

<div class="flex w-full flex-row gap-x-4 p-2">
  {#if isLeaf}
    <div class="relative mr-4 flex w-28 flex-row font-mono font-medium text-neutral-500 md:w-36">
      <div class="z-100 sticky top-16 flex w-full flex-col gap-y-2 self-start">
        {#if displayPath != '' && titleValue == null}
          <div title={displayPath} class="mx-2 mt-2 w-full flex-initial truncate">
            {displayPath}
          </div>
        {/if}
        <div class="flex flex-row gap-x-1">
          <div
            use:hoverTooltip={{
              text: noEmbeddings ? '"More like this" requires an embedding index' : undefined
            }}
            class:opacity-50={noEmbeddings}
          >
            <button
              disabled={noEmbeddings}
              on:click={() => findSimilar(value)}
              use:hoverTooltip={{text: 'More like this'}}
              ><Search size={16} />
            </button>
          </div>
          <button
            disabled={colCompareState != null}
            class:opacity-50={colCompareState != null}
            on:click={() => (userPreview = !markdown)}
            use:hoverTooltip={{text: !markdown ? 'Preview markdown' : 'Back to text'}}
            >{#if markdown}<CatalogPublish size={16} />{:else}<DataViewAlt size={16} />{/if}
          </button>
          {#if !colCompareState}
            <ButtonDropdown
              disabled={compareItems.length === 0}
              helperText={'Compare to'}
              items={compareItems}
              buttonIcon={DirectionFork}
              on:select={selectCompareColumn}
              hoist={true}
            />
          {:else}
            <button
              on:click={() => removeComparison()}
              use:hoverTooltip={{text: 'Remove comparison'}}
              ><Undo size={16} />
            </button>
          {/if}

          <button
            on:click={() =>
              ($datasetViewStore.showMetadataPanel = !$datasetViewStore.showMetadataPanel)}
            use:hoverTooltip={{
              text: $datasetViewStore.showMetadataPanel
                ? 'Collapse metadata panel'
                : 'Expand metadata panel'
            }}
            >{#if $datasetViewStore.showMetadataPanel}<DataBackup size={16} />{:else}<DataView
                size={16}
              />{/if}
          </button>
          <button
            disabled={!textIsOverBudget}
            class:opacity-50={!textIsOverBudget}
            on:click={() => (userExpanded = !userExpanded)}
            use:hoverTooltip={{text: userExpanded ? 'Collapse text' : 'Expand text'}}
            >{#if userExpanded}<ChevronUp size={16} />{:else}<ChevronDown size={16} />{/if}
          </button>
        </div>
      </div>
    </div>
    <div class="flex grow flex-col font-normal">
      {#if titleValue != null}
        <div
          class="mb-1 ml-11 rounded bg-gray-100 p-1 px-2 text-xs font-bold uppercase text-gray-700"
        >
          {titleValue}
        </div>
      {/if}

      <div class="grow pt-1">
        {#if isFetching}
          <SkeletonText class="!w-80" />
        {:else if value == null || row == null}
          <span class="ml-12 italic">null</span>
        {:else if colCompareState == null}
          <ItemMediaTextContent
            hidden={markdown}
            text={value}
            {row}
            path={rootPath}
            {field}
            isExpanded={userExpanded}
            spanPaths={spanValuePaths.spanPaths}
            spanValueInfos={spanValuePaths.spanValueInfos}
            {datasetViewStore}
            embeddings={computedEmbeddings}
            {viewType}
            bind:textIsOverBudget
          />
          <div class="markdown w-full" class:hidden={!markdown}>
            <div class="markdown -ml-0.5 w-fit pl-14">
              <SvelteMarkdown source={formatValue(value)} />
            </div>
          </div>
        {:else}
          <ItemMediaDiff {row} {colCompareState} bind:textIsOverBudget isExpanded={userExpanded} />
        {/if}
      </div>
    </div>
  {:else}
    <!-- Repeated values will render <ItemMedia> again. -->
    <div class="my-2 flex w-full flex-col rounded border border-neutral-200">
      <div class="m-2 flex flex-col gap-y-2">
        <div title={displayPath} class="mx-2 my-2 truncate font-mono font-medium text-neutral-500">
          {displayPath}
        </div>
        {#each nextRootPaths as nextRootPath}
          <div class="m-2 rounded border border-neutral-100">
            <svelte:self
              rootPath={nextRootPath.rootPath}
              showPath={nextRootPath.showPath}
              {row}
              {field}
              {highlightedFields}
              {mediaPath}
            />
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
