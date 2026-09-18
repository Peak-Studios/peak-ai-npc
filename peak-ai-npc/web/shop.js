(() => {
    const byId = id => document.getElementById(id);
    const panel = byId('shopShowcase');
    const grid = byId('shopGrid');
    const buy = byId('buySelectedItem');
    const sell = byId('sellSelectedItem');
    const status = byId('shopStatus');
    let catalog = null;
    let selected = null;
    let quantity = 1;
    let category = 'all';
    let quote = null;
    let pending = false;
    let timer = null;
    let generation = 0;
    let requestSequence = 0;
    let activeRequest = null;
    let received = new Set();
    window.PeakShop = Object.freeze({ isOpen: () => catalog !== null && !panel.hidden });
    const money = value => Number.isFinite(value) ? `$${value.toLocaleString('en-US')}` : 'Unavailable';
    const validInteger = value => Number.isSafeInteger(value) && value >= 0;
    const resourceName = window.GetParentResourceName ? window.GetParentResourceName() : 'peak-ai-npc';

    async function post(action, data = {}) {
        const response = await fetch(`https://${resourceName}/${action}`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data)
        });
        const result = await response.json();
        if (!response.ok || result.ok !== true) throw new Error('request_failed');
        return result;
    }

    function controls() {
        byId('selectedItemLabel').textContent = selected?.label || 'Select an item';
        byId('selectedItemPrice').textContent = selected ? `${money(selected.price)} each · ${selected.stock} in stock` : '';
        byId('selectedQty').textContent = String(quantity);
        buy.disabled = pending || !selected || (!quote && selected.stock < quantity);
        sell.disabled = pending || !selected || !validInteger(selected.buyPrice) || selected.buyPrice < 1;
        byId('qtyMinus').disabled = pending || quantity <= 1;
        byId('qtyPlus').disabled = pending || quantity >= (selected?.maximumQuantity || 20);
        byId('askNpcAboutItem').disabled = pending || !selected;
        buy.textContent = quote?.kind === 'buy' ? `Confirm buy · ${money(quote.total)}` : 'Get buy quote';
        sell.textContent = quote?.kind === 'sell' ? `Confirm sell · ${money(quote.total)}` : 'Get sell quote';
    }

    function close() {
        generation++;
        clearTimeout(timer);
        timer = null;
        catalog = selected = quote = null;
        activeRequest = null;
        received = new Set();
        pending = false;
        panel.hidden = true;
        grid.replaceChildren();
        controls();
    }

    function render() {
        grid.replaceChildren();
        for (const item of catalog?.items || []) {
            if (category !== 'all' && item.category !== category) continue;
            const card = document.createElement('button');
            card.type = 'button';
            card.className = `item-card${selected?.item === item.item ? ' selected' : ''}`;
            card.setAttribute('aria-pressed', String(selected?.item === item.item));
            const label = document.createElement('strong');
            label.textContent = item.label;
            const price = document.createElement('span');
            price.textContent = money(item.price);
            const description = document.createElement('p');
            description.textContent = item.description;
            card.append(label, price, description);
            card.disabled = pending;
            card.addEventListener('click', () => {
                if (pending) return;
                selected = item;
                quantity = 1;
                quote = null;
                activeRequest = null;
                status.textContent = 'Request a quote, then confirm the exact total.';
                render();
            });
            grid.append(card);
        }
        if (!grid.children.length) {
            const empty = document.createElement('p');
            empty.textContent = 'No available items in this category.';
            grid.append(empty);
        }
        controls();
    }

    async function request(kind) {
        if (pending || !selected || !catalog) return;
        const expected = generation;
        const confirmed = quote?.kind === kind;
        const requestId = `${generation}:${++requestSequence}`;
        activeRequest = requestId;
        pending = true;
        status.textContent = confirmed ? 'Completing transaction…' : 'Checking price and stock…';
        render();
        clearTimeout(timer);
        timer = setTimeout(() => {
            if (generation !== expected) return;
            pending = false;
            // Keep the same quote for a confirmation retry. Never create a new
            // paid operation merely because a response was delayed or lost.
            status.textContent = confirmed ? 'No receipt yet. Confirm again to check the same transaction.' : 'The shop did not respond. Close and reopen it to refresh.';
            controls();
        }, 10000);
        try {
            await post(confirmed ? 'buyShopItem' : 'quoteShopItem', confirmed
                ? { quoteId: quote.id, requestId }
                : { item: selected.item, quantity, kind, requestId });
        } catch {
            if (generation !== expected) return;
            clearTimeout(timer);
            pending = false;
            status.textContent = 'The request could not be sent. Close the shop or try again.';
            render();
        }
    }

    byId('openShop').addEventListener('click', () => post('openShop').catch(() => {
        byId('status').textContent = 'The shop could not open. Try again when the NPC is ready.';
    }));
    byId('closeShop').addEventListener('click', () => { close(); post('closeShop').catch(() => {}); });
    buy.addEventListener('click', () => request('buy'));
    sell.addEventListener('click', () => request('sell'));
    for (const [id, change] of [['qtyMinus', -1], ['qtyPlus', 1]]) {
        byId(id).addEventListener('click', () => {
            if (pending) return;
            quantity = Math.max(1, Math.min(selected?.maximumQuantity || 20, quantity + change));
            quote = null;
            activeRequest = null;
            controls();
        });
    }
    byId('shopTabs').addEventListener('click', event => {
        const button = event.target.closest('[data-category]');
        if (!button || pending) return;
        category = button.dataset.category;
        for (const tab of byId('shopTabs').querySelectorAll('[data-category]')) tab.classList.toggle('active', tab === button);
        render();
    });
    byId('askNpcAboutItem').addEventListener('click', () => {
        if (!selected || pending) return;
        const label = selected.label;
        close();
        post('closeShop', { keepCursor: true }).catch(() => {});
        if (byId('form').hidden) byId('textToggle').click();
        byId('input').value = `Tell me about ${label}.`;
        byId('input').focus();
    });
    window.addEventListener('keydown', event => {
        if (event.key === 'Escape' && !panel.hidden) {
            event.preventDefault();
            close();
            post('closeShop').catch(() => {});
        }
    });
    window.addEventListener('pagehide', close);
    window.addEventListener('message', event => {
        const { action, data } = event.data || {};
        if (action === 'close' || action === 'closeShop') { close(); return; }
        if (action === 'state') {
            const payload = data?.payload || {};
            if (payload.nearby === true) return;
            byId('openShop').hidden = payload.shopAvailable !== true;
            if (catalog && (payload.sessionId !== catalog.sessionId || payload.sessionRevision !== catalog.sessionRevision)) close();
        }
        if (action === 'shopCatalog') {
            if (!data || !Array.isArray(data.items) || typeof data.sessionId !== 'string') return;
            close();
            catalog = { ...data, items: data.items.filter(item => item && typeof item.item === 'string'
                && typeof item.label === 'string' && validInteger(item.price) && item.price > 0 && validInteger(item.stock)) };
            category = 'all';
            byId('shopName').textContent = data.shopName || 'Store';
            byId('shopSubtitle').textContent = data.occupation || 'Shopkeeper';
            byId('playerCashDisplay').textContent = money(data.cash);
            status.textContent = 'Select an item to request a quote.';
            panel.hidden = false;
            render();
            byId('closeShop').focus();
        }
        if (action === 'shopResult' && catalog) {
            if (!activeRequest || data?.requestId !== activeRequest) return;
            if (data?.sessionId && (data.sessionId !== catalog.sessionId || data.sessionRevision !== catalog.sessionRevision)) return;
            clearTimeout(timer);
            activeRequest = null;
            pending = false;
            byId('playerCashDisplay').textContent = money(data?.cash);
            if (data?.ok && data.result?.requiresConfirmation && typeof data.result.id === 'string') {
                quote = data.result;
                status.textContent = `${quote.kind === 'sell' ? 'Sell' : 'Buy'} ${quantity} × ${selected?.label || 'item'} for ${money(quote.total)}. Confirm within 30 seconds.`;
            } else if (data?.ok && data.result?.quoteId) {
                for (const entry of received.has(data.result.quoteId) ? [] : data.result.items || []) {
                    const row = catalog.items.find(item => item.item === entry.item);
                    if (row) row.stock += data.result.kind === 'sell' ? entry.quantity : -entry.quantity;
                }
                received.add(data.result.quoteId);
                quote = null;
                status.textContent = `Transaction complete · ${money(data.result.total)}.`;
            } else {
                const reason = typeof data?.result === 'string' ? data.result : 'shop_unavailable';
                quote = null;
                status.textContent = reason === 'transaction_outcome_unknown'
                    ? 'Transaction needs administrator review. Do not start another purchase.'
                    : `Could not complete: ${reason.replaceAll('_', ' ')}. Request a fresh quote when ready.`;
            }
            render();
        }
    });
})();
